// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {SafeChain} from "src/libraries/SafeChain.sol";
import {BalancerPoolManager} from "src/contracts/BalancerPoolManager.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IRouterClient, Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {CrossChainRequest} from "src/libraries/CrossChainRequest.sol";
import {CustomCast} from "src/libraries/CustomCast.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {RequestReceipt} from "src/libraries/RequestReceipt.sol";
import {SafeCrossChainReceipt} from "src/libraries/SafeCrossChainReceipt.sol";
import {NetworkHelper} from "src/libraries/NetworkHelper.sol";
import {Arrays} from "src/libraries/Arrays.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Swap} from "src/contracts/Swap.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract PoolManager is CCIPReceiver, AccessControlDefaultAdminRules, BalancerPoolManager, Swap {
	using SafeChain for uint256;
	using Strings for uint256;
	using CustomCast for address[];
	using SafeCrossChainReceipt for RequestReceipt.CrossChainReceiptType;
	using SafeCrossChainReceipt for RequestReceipt.CrossChainSuccessReceiptType;
	using SafeCrossChainReceipt for RequestReceipt.CrossChainFailureReceiptType;
	using EnumerableSet for EnumerableSet.UintSet;
	using SafeERC20 for IERC20;

	enum PoolStatus {
		NOT_CREATED,
		ACTIVE,
		CREATING
	}

	enum DepositStatus {
		NOT_DEPOSITED,
		DEPOSITED,
		PENDING,
		FAILED
	}

	struct ChainPool {
		address poolAddress;
		address[] poolTokens;
		bytes32 poolId;
		PoolStatus status;
	}

	struct ChainDeposit {
		DepositStatus status;
		address user;
		uint256 receivedBPT;
		uint256 usdcAmount;
	}

	uint256 private constant CREATE_POOL_GAS_LIMIT = 3_000_000;
	uint256 private constant DEPOSIT_GAS_LIMIT = 3_000_000; // TODO: Check how much gas is needed
	uint48 private constant ADMIN_TRANSFER_DELAY = 7 days;

	bytes32 public constant TOKENS_MANAGER_ROLE = "TOKENS_MANAGER";

	IRouterClient private immutable i_ccipRouterClient;

	mapping(uint256 chainId => address crossChainPoolManager) private s_chainCrossChainPoolManager;
	mapping(bytes32 depositId => mapping(uint256 chainId => ChainDeposit)) private s_deposits;
	mapping(uint256 chainId => ChainPool pool) private s_chainPool;
	EnumerableSet.UintSet internal s_chainsSet;
	IERC20 internal s_usdc;

	/// @notice emitted once the Pool for the same chain as the CTF is successfully created.
	event PoolManager__SameChainPoolCreated(bytes32 indexed poolId, address indexed poolAddress, address[] tokens);

	/// @notice emitted once a deposit is made in the same chain is made in the CTF
	event PoolManager__SameChainDeposited(address indexed forUser, bytes32 indexed depositId);

	/// @notice emitted once a cross chain deposit is requested
	event PoolManager__CrossChainDepositRequested(
		bytes32 indexed depositId,
		uint256 indexed chainId,
		address indexed user,
		bytes32 messageId,
		uint256 usdcAmount
	);

	/// @notice emitted once the CrossChainPoolManager for the given chain is set
	event PoolManager__CrossChainPoolManagerSet(uint256 indexed chainId, address indexed crossChainPoolManager);

	/// @notice emitted once the message to create a pool in another chain is sent
	event PoolManager__CrossChainCreatePoolRequested(
		address indexed crossChainPoolManager,
		bytes32 indexed messageId,
		uint256 indexed chainId,
		address[] tokens,
		string poolName
	);

	/// @notice emitted once the cross chain pool creation receipt is received
	event PoolManager__CrossChainPoolCreated(address indexed poolAddress, bytes32 indexed poolId, uint256 indexed chainId);

	/// @notice emitted once an amount of ETH has been withdrawn from the Pool Manager
	event PoolManager__ETHWithdrawn(uint256 amount);

	/// @notice emitted once the USDC address has been changed
	event PoolManager__USDCAddressChanged(address newAddress, address oldAddress);

	/// @notice emitted once the deposits on all pools across all chains have been confirmed
	event PoolManager__AllDepositsConfirmed(bytes32 indexed depositId, address indexed user);

	/**
	 * @notice emitted when the Pool Manager receives the Cross Chain Pool not created receipt
	 * from the Cross Chain Pool Manager.
	 *  */
	event PoolManager__FailedToCreateCrossChainPool(uint256 chainId, address crossChainPoolManager);

	/// @notice emitted when the Pool Manager receives the Cross Chain Deposit failed receipt
	event PoolManager__FailedToDeposit(address indexed forUser, bytes32 indexed depositId, uint256 usdcAmount);

	/// @notice thrown if the pool has already been created and the CTF is trying to create it again
	error PoolManager__PoolAlreadyCreated(address poolAddress, uint256 chainId);

	/**
	 * @notice thrown if the CrossChain Pool manager for the given chain have not been found.
	 * it can be due to the missing call to `setCrossChainPoolManager` or actually not existing yet
	 *  */
	error PoolManager__CrossChainPoolManagerNotFound(uint256 chainId);

	/**
	 * @notice thrown if the ccip chain selector for the given chain have not been found.
	 * it can be due to the missing call to `setChainSelector` or actually not existing yet
	 */
	error PoolManager__ChainSelectorNotFound(uint256 chainId);

	/// @notice thrown if the admin tries to add a CrossChainPoolManager for the same chain as the CTF
	error PoolManager__CannotAddCrossChainPoolManagerForTheSameChain();

	/// @notice thrown if the admin tries to add a ccip chain selector for the same chain as the CTF
	error PoolManager__CannotAddChainSelectorForTheSameChain();

	/// @notice thrown if the CrossChainPoolManager for the given chain have already been set
	error PoolManager__CrossChainPoolManagerAlreadySet(address crossChainPoolManager);

	/// @notice thrown if the adming tries to add a CrossChainPoolManager with an invalid address
	error PoolManager__InvalidPoolManager();

	/// @notice thrown if the admin tries to add a ccip chain selector with an invalid value
	error PoolManager__InvalidChainSelector();

	/// @notice thrown if the sender of the Cross Chain Receipt is not a registered Cross Chain Pool Manager
	error PoolManager__InvalidReceiptSender(address sender, address crossChainPoolManager);

	/// @notice thrown when the ETH witdraw fails for some reason
	error PoolManager__FailedToWithdrawETH(bytes data);

	/**
	 * @notice thrown when the chainid passed is not mapped.
	 * @custom:note this is not used in the create pool function, as they will add the chain
	 *  */
	error PoolManager__UnknownChain(uint256 chainId);

	///  @notice thrown when the pool for the given chain is not active yet
	error PoolManager__PoolNotActive(uint256 chainId);

	/// @notice thrown if the USDC address passed is invalid
	error PoolManager__InvalidUSDC(address usdcAddress);

	constructor(
		address balancerManagedPoolFactory,
		address balancerVault,
		address ccipRouterClient,
		address admin
	)
		BalancerPoolManager(balancerManagedPoolFactory, balancerVault)
		AccessControlDefaultAdminRules(ADMIN_TRANSFER_DELAY, admin)
		CCIPReceiver(ccipRouterClient)
	{
		i_ccipRouterClient = IRouterClient(ccipRouterClient);
		s_chainsSet.add(block.chainid);
		s_usdc = IERC20(NetworkHelper._getUSDC());
	}

	receive() external payable {}

	/**
	 * @notice withdraw ETH from the CTF. Only the admin can perform this action
	 * @param amount the amount of ETH to withdraw (with decimals)
	 * @custom:note this only withdraw the ETH used to cover infrastructural costs
	 * it doesn't withdraw users deposited funds
	 *  */
	function withdrawETH(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
		//slither-disable-next-line arbitrary-send-eth
		(bool success, bytes memory data) = defaultAdmin().call{value: amount}("");

		if (!success) revert PoolManager__FailedToWithdrawETH(data);

		emit PoolManager__ETHWithdrawn(amount);
	}

	/**
	 * @notice set the USDC token address. Only the admin can perform this action
	 * @param usdc the new address of USDC
	 */
	function setUSDC(address usdc) external onlyRole(DEFAULT_ADMIN_ROLE) {
		if (usdc.code.length == 0) revert PoolManager__InvalidUSDC(usdc);

		emit PoolManager__USDCAddressChanged(usdc, address(s_usdc));

		s_usdc = IERC20(usdc);
	}

	/**
	 * @notice set the Cross Cross Chain Pool Manager contract for the given chain.
	 * Only the tokens manager can set it.
	 * @param crossChainPoolManager the address of the Cross Chain Pool Manager at the given chain
	 * @param chainId the chain id of the given `crossChainPoolManager` address
	 *  */
	function setCrossChainPoolManager(uint256 chainId, address crossChainPoolManager) external onlyRole(TOKENS_MANAGER_ROLE) {
		address currentCrossChainPoolManager = s_chainCrossChainPoolManager[chainId];

		if (chainId.isCurrent()) revert PoolManager__CannotAddCrossChainPoolManagerForTheSameChain();
		if (crossChainPoolManager == address(0)) revert PoolManager__InvalidPoolManager();
		if (currentCrossChainPoolManager != address(0)) {
			revert PoolManager__CrossChainPoolManagerAlreadySet(currentCrossChainPoolManager);
		}

		s_chainCrossChainPoolManager[chainId] = crossChainPoolManager;

		emit PoolManager__CrossChainPoolManagerSet(chainId, crossChainPoolManager);
	}

	/// @notice get the USDC address used by the Pool Manager
	function getUSDC() external view returns (address) {
		return address(s_usdc);
	}

	/**
	 * @notice get the chains that the underlying tokens are on
	 * @return chains the array of chains without duplicates
	 *  */
	function getChains() external view returns (uint256[] memory chains) {
		return s_chainsSet.values();
	}

	/**
	 * @notice get the Cross Chain Pool Manager contract for the given chain
	 * @param chainId the chain id that the Cross Chain Pool Manager contract is in
	 *  */
	function getCrossChainPoolManager(uint256 chainId) external view returns (address) {
		return s_chainCrossChainPoolManager[chainId];
	}

	/**
	 * @notice get the Pool info for the given chain
	 * @param chainId the chain id that the Pool contract is in
	 *  */
	function getChainPool(uint256 chainId) public view returns (ChainPool memory) {
		return s_chainPool[chainId];
	}

	function supportsInterface(bytes4 interfaceId) public view override(AccessControlDefaultAdminRules, CCIPReceiver) returns (bool) {
		return AccessControlDefaultAdminRules.supportsInterface(interfaceId) || CCIPReceiver.supportsInterface(interfaceId);
	}

	function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
		RequestReceipt.CrossChainReceipt memory receipt = abi.decode(message.data, (RequestReceipt.CrossChainReceipt));
		address ccipSender = abi.decode(message.sender, (address));
		address crossChainPoolManager = s_chainCrossChainPoolManager[receipt.chainId];

		if (ccipSender != crossChainPoolManager) revert PoolManager__InvalidReceiptSender(ccipSender, crossChainPoolManager);

		if (receipt.receiptType.isSuccess()) {
			RequestReceipt.CrossChainSuccessReceiptType successTypeReceipt = abi.decode(
				receipt.data,
				(RequestReceipt.CrossChainSuccessReceiptType)
			);
			_handleCrossChainSuccessReceipt(receipt.chainId, successTypeReceipt, receipt);
		} else {
			RequestReceipt.CrossChainFailureReceiptType failureTypeReceipt = abi.decode(
				receipt.data,
				(RequestReceipt.CrossChainFailureReceiptType)
			);
			_handleCrossChainFailureReceipt(receipt.chainId, failureTypeReceipt, receipt, ccipSender);
		}
	}

	function _onCreatePool(uint256 chainId, address[] memory tokens) internal virtual;

	function _onDeposit(address user, uint256 totalBPTReceived) internal virtual;

	function _requestPoolDeposit(
		bytes32 depositId,
		uint256 chainId,
		address[] memory assets,
		address swapProvider,
		bytes[] calldata swapsCalldata,
		uint256 minBPTOut,
		uint256 depositUSDCAmount
	) internal {
		assets = Arrays.sort(assets);
		IERC20 usdc = s_usdc;

		if (!s_chainsSet.contains(chainId)) revert PoolManager__UnknownChain(chainId);
		ChainPool memory chainPool = s_chainPool[chainId];

		if (chainPool.status != PoolStatus.ACTIVE) revert PoolManager__PoolNotActive(chainId);

		if (chainId.isCurrent()) {
			_swapUSDC(IERC20(usdc), depositUSDCAmount, swapProvider, swapsCalldata);
			uint256 bptReceived = _joinPool(chainPool.poolId, assets.toIAssetList(), minBPTOut);

			s_deposits[depositId][chainId] = ChainDeposit(DepositStatus.DEPOSITED, msg.sender, bptReceived, depositUSDCAmount);
			if (s_chainsSet.length() == 1) _onDeposit(msg.sender, bptReceived);

			emit PoolManager__SameChainDeposited(msg.sender, depositId);
		} else {
			s_deposits[depositId][chainId] = ChainDeposit(DepositStatus.PENDING, msg.sender, 0, depositUSDCAmount);
			address crossChainPoolManager = s_chainCrossChainPoolManager[chainId];
			uint64 chainSelector = NetworkHelper._getCCIPChainSelector(chainId);

			if (crossChainPoolManager == address(0)) revert PoolManager__CrossChainPoolManagerNotFound(chainId);
			if (chainSelector == 0) revert PoolManager__ChainSelectorNotFound(chainId);

			bytes memory messageData = abi.encode(
				CrossChainRequest.CrossChainRequestType.DEPOSIT,
				CrossChainRequest.CrossChainDepositRequest({
					depositId: depositId,
					joinTokens: assets.toIAssetList(),
					poolId: chainPool.poolId,
					minBPTOut: minBPTOut,
					swapProvider: swapProvider,
					swapsCalldata: swapsCalldata
				})
			);

			bytes32 messageId;

			// we use scopes here because somehow, stack too deep error is being thrown
			{
				(Client.EVM2AnyMessage memory message, uint256 fee) = _buildCrossChainMessage(
					chainId,
					DEPOSIT_GAS_LIMIT,
					depositUSDCAmount,
					messageData
				);

				usdc.forceApprove(address(i_ccipRouterClient), depositUSDCAmount);
				messageId = i_ccipRouterClient.ccipSend{value: fee}(chainSelector, message);
			}

			emit PoolManager__CrossChainDepositRequested(depositId, chainId, msg.sender, messageId, depositUSDCAmount);
		}
	}

	/**
	 * @notice Create a new pool with the given Tokens for the given chain
	 * @param chainId the chain that the pool will be created on
	 * @param tokens the tokens that will be added to the pool
	 */
	function _requestNewPoolCreation(uint256 chainId, string memory poolName, address[] memory tokens) internal {
		ChainPool memory chainPool = s_chainPool[chainId];

		// sort the tokens in ascending order
		// balancer requires the tokens in ascending order
		tokens = Arrays.sort(tokens);

		if (chainPool.status != PoolStatus.NOT_CREATED) revert PoolManager__PoolAlreadyCreated(chainPool.poolAddress, chainId);

		if (chainId.isCurrent()) {
			s_chainPool[chainId].poolTokens = tokens;
			s_chainPool[chainId].status = PoolStatus.ACTIVE;

			(address poolAddress, bytes32 poolId) = _createPool(poolName, chainId.toString(), tokens.toIERC20List());

			//slither-disable-start reentrancy-no-eth
			s_chainPool[chainId].poolAddress = poolAddress;
			s_chainPool[chainId].poolId = poolId;
			//slither-disable-end reentrancy-no-eth

			_onCreatePool(chainId, tokens);

			emit PoolManager__SameChainPoolCreated(poolId, poolAddress, tokens);
		} else {
			s_chainPool[chainId].status = PoolStatus.CREATING;
			address crossChainPoolManager = s_chainCrossChainPoolManager[chainId];
			uint64 chainSelector = NetworkHelper._getCCIPChainSelector(chainId);

			if (crossChainPoolManager == address(0)) revert PoolManager__CrossChainPoolManagerNotFound(chainId);
			if (chainSelector == 0) revert PoolManager__ChainSelectorNotFound(chainId);

			bytes memory messageData = abi.encode(
				CrossChainRequest.CrossChainRequestType.CREATE_POOL,
				CrossChainRequest.CrossChainCreatePoolRequest({tokens: tokens, poolName: poolName})
			);

			(Client.EVM2AnyMessage memory message, uint256 fee) = _buildCrossChainMessage(chainId, CREATE_POOL_GAS_LIMIT, 0, messageData);
			//slither-disable-next-line arbitrary-send-eth
			bytes32 messageId = i_ccipRouterClient.ccipSend{value: fee}(chainSelector, message);

			emit PoolManager__CrossChainCreatePoolRequested(crossChainPoolManager, messageId, chainId, tokens, poolName);
		}
	}

	/**
	 * @notice Add the given token to an existing pool at the given chain
	 * @param chainId the chain that the pool is in
	 * @param token the token that will be added to the pool
	 * @param pool the pool that the token will be added to
	 */
	function _requestTokenAddition(uint256 chainId, address token, address pool) internal {
		ChainPool memory chainPool = s_chainPool[chainId];

		if (chainId.isCurrent()) {} else {}
	}

	/**
	 * @notice Batch token add for the given pool at the given chain
	 * @param chainId the chain that the pool is in
	 * @param tokens the tokens that will be added to the pool
	 * @param pool the pool that the token will be added to
	 */
	function _requestBatchTokenAddition(uint256 chainId, address[] memory tokens, address pool) internal {
		ChainPool memory chainPool = s_chainPool[chainId];

		if (chainId.isCurrent()) {} else {}
	}

	function _handleCrossChainSuccessReceipt(
		uint256 chainId,
		RequestReceipt.CrossChainSuccessReceiptType successTypeReceipt,
		RequestReceipt.CrossChainReceipt memory receipt
	) private {
		if (successTypeReceipt.isPoolCreated()) {
			(, RequestReceipt.CrossChainPoolCreatedReceipt memory receiptPoolCreated) = abi.decode(
				receipt.data,
				(RequestReceipt.CrossChainSuccessReceiptType, RequestReceipt.CrossChainPoolCreatedReceipt)
			);

			return _handleCrossChainPoolCreatedReceipt(chainId, receiptPoolCreated);
		}

		if (successTypeReceipt.isDeposited()) {
			(, RequestReceipt.CrossChainDepositedReceipt memory receiptDeposited) = abi.decode(
				receipt.data,
				(RequestReceipt.CrossChainSuccessReceiptType, RequestReceipt.CrossChainDepositedReceipt)
			);

			return _handleCrossChainDepositedReceipt(chainId, receiptDeposited);
		}
	}

	function _handleCrossChainFailureReceipt(
		uint256 chainId,
		RequestReceipt.CrossChainFailureReceiptType failureTypeReceipt,
		RequestReceipt.CrossChainReceipt memory receipt,
		address sender
	) private {
		if (failureTypeReceipt.isPoolNotCreated()) {
			emit PoolManager__FailedToCreateCrossChainPool(chainId, sender);
			return;
		}

		if (failureTypeReceipt.isNotDeposited()) {
			(, RequestReceipt.CrossChainDepositFailedReceipt memory depositFailedReceipt) = abi.decode(
				receipt.data,
				(RequestReceipt.CrossChainFailureReceiptType, RequestReceipt.CrossChainDepositFailedReceipt)
			);

			return _handleCrossChainDepositFailure(chainId, depositFailedReceipt);
		}
	}

	function _handleCrossChainPoolCreatedReceipt(uint256 chainId, RequestReceipt.CrossChainPoolCreatedReceipt memory receipt) private {
		ChainPool memory chainPool = s_chainPool[chainId];
		if (chainPool.status == PoolStatus.ACTIVE) revert PoolManager__PoolAlreadyCreated(chainPool.poolAddress, chainId);

		s_chainsSet.add(chainId);
		s_chainPool[chainId] = ChainPool({
			status: PoolStatus.ACTIVE,
			poolAddress: receipt.poolAddress,
			poolId: receipt.poolId,
			poolTokens: receipt.tokens
		});

		_onCreatePool(chainId, receipt.tokens);

		emit PoolManager__CrossChainPoolCreated(receipt.poolAddress, receipt.poolId, chainId);
	}

	function _handleCrossChainDepositedReceipt(uint256 chainId, RequestReceipt.CrossChainDepositedReceipt memory receipt) private {
		uint256 chains = s_chainsSet.length();
		uint256 confirmedDeposits;
		uint256 totalReceivedBpt;
		address user = s_deposits[receipt.depositId][chainId].user;

		s_deposits[receipt.depositId][chainId].status = DepositStatus.DEPOSITED;
		s_deposits[receipt.depositId][chainId].receivedBPT = receipt.receivedBPT;

		for (uint256 i = 0; i < chains; ) {
			ChainDeposit memory chainDeposit = s_deposits[receipt.depositId][s_chainsSet.at(i)];

			if (chainDeposit.status == DepositStatus.DEPOSITED) {
				++confirmedDeposits;
				totalReceivedBpt += chainDeposit.receivedBPT;
			}

			unchecked {
				++i;
			}
		}

		if (chains == confirmedDeposits) {
			emit PoolManager__AllDepositsConfirmed(receipt.depositId, user);

			_onDeposit(user, totalReceivedBpt);
		}
	}

	function _handleCrossChainDepositFailure(
		uint256 chainId,
		RequestReceipt.CrossChainDepositFailedReceipt memory depositFailedReceipt
	) private {
		uint256 chainsCount = s_chainsSet.length();
		address user = s_deposits[depositFailedReceipt.depositId][chainId].user;
		uint256 failedChainsCount;
		uint256 totalDepositAmount;

		s_deposits[depositFailedReceipt.depositId][chainId].status = DepositStatus.FAILED;

		for (uint256 i = 0; i < chainsCount; ) {
			ChainDeposit memory chainDeposit = s_deposits[depositFailedReceipt.depositId][s_chainsSet.at(i)];
			totalDepositAmount += chainDeposit.usdcAmount;

			if (chainDeposit.status == DepositStatus.FAILED) {
				++failedChainsCount;
			}

			if (chainDeposit.status == DepositStatus.DEPOSITED) {
				// TODO: WITHDRAW request from chain
			}

			unchecked {
				++i;
			}
		}

		if (chainsCount == failedChainsCount) {
			emit PoolManager__FailedToDeposit(user, depositFailedReceipt.depositId, totalDepositAmount);

			s_usdc.safeTransfer(user, totalDepositAmount);
		}
	}

	/**
	 * @dev build CCIP Message to send to another chain
	 * @param chainId the chain that the CrossChainPoolManager is in
	 * @param gasLimit the gas limit for the transaction in the other chain
	 * @param usdcAmount the amount of USDC to send, if zero, no usdc will be sent
	 * @param data the encoded data to pass to the CrossChainPoolManager
	 * @return message the CCIP Message to be sent
	 * @return fee the ccip fee to send this message, note that the fee will be in ETH
	 */
	function _buildCrossChainMessage(
		uint256 chainId,
		uint256 gasLimit,
		uint256 usdcAmount,
		bytes memory data
	) private view returns (Client.EVM2AnyMessage memory message, uint256 fee) {
		Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](0); // TODO: Check if needed to assign the variable

		if (usdcAmount != 0) {
			tokenAmounts = new Client.EVMTokenAmount[](1);
			tokenAmounts[0] = Client.EVMTokenAmount({token: address(s_usdc), amount: usdcAmount});
		}

		message = Client.EVM2AnyMessage({
			receiver: abi.encode(s_chainCrossChainPoolManager[chainId]),
			data: data,
			tokenAmounts: tokenAmounts,
			feeToken: address(0),
			extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: gasLimit}))
		});

		fee = i_ccipRouterClient.getFee(NetworkHelper._getCCIPChainSelector(chainId), message);

		return (message, fee);
	}
}
