// SPDX-License-Identifier: MIT
// solhint-disable chainlink-solidity/prefix-internal-functions-with-underscore
pragma solidity 0.8.25;

library RequestReceipt {
	enum CrossChainReceiptType {
		SUCCESS,
		FAILURE
	}

	enum CrossChainSuccessReceiptType {
		POOL_CREATED,
		DEPOSITED,
		WITHDRAW
	}

	enum CrossChainFailureReceiptType {
		POOL_CREATION_FAILED,
		TOKEN_ADDITION_FAILED
	}

	struct CrossChainPoolCreatedReceipt {
		address poolAddress;
		bytes32 poolId;
		address[] tokens;
		uint256[] weights;
	}

	struct CrossChainDepositedReceipt {
		bytes32 depositId;
		uint256 receivedBPT;
	}

	struct CrossChainWithdrawReceipt {
		bytes32 withdrawId;
		uint256 receivedUSDC;
	}

	struct CrossChainDepositFailedReceipt {
		bytes32 depositId;
	}

	struct CrossChainReceipt {
		CrossChainReceiptType receiptType;
		uint256 chainId;
		bytes data;
	}

	function crossChainPoolCreatedReceipt(
		address poolAddress,
		bytes32 poolId,
		address[] memory tokens,
		uint256[] memory weights
	) internal view returns (CrossChainReceipt memory) {
		return
			_successReceipt(
				abi.encode(
					CrossChainSuccessReceiptType.POOL_CREATED,
					CrossChainPoolCreatedReceipt({poolAddress: poolAddress, poolId: poolId, tokens: tokens, weights: weights})
				)
			);
	}

	function crossChainDepositedReceipt(bytes32 depositId, uint256 bptReceived) internal view returns (CrossChainReceipt memory) {
		return _successReceipt(abi.encode(CrossChainSuccessReceiptType.DEPOSITED, CrossChainDepositedReceipt(depositId, bptReceived)));
	}

	function crossChainWithdrawnReceipt(bytes32 withdrawId, uint256 usdcReceived) internal view returns (CrossChainReceipt memory) {
		return _successReceipt(abi.encode(CrossChainSuccessReceiptType.WITHDRAW, CrossChainWithdrawReceipt(withdrawId, usdcReceived)));
	}

	function crossChainGenericFailedReceipt(
		CrossChainFailureReceiptType failureReceiptType
	) internal view returns (CrossChainReceipt memory) {
		return _failureReceipt(abi.encode(failureReceiptType));
	}

	function _successReceipt(bytes memory data) private view returns (CrossChainReceipt memory) {
		return CrossChainReceipt({receiptType: CrossChainReceiptType.SUCCESS, chainId: block.chainid, data: data});
	}

	function _failureReceipt(bytes memory data) private view returns (CrossChainReceipt memory) {
		return CrossChainReceipt({receiptType: CrossChainReceiptType.FAILURE, chainId: block.chainid, data: data});
	}
}
