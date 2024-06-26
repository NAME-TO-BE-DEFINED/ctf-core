// SPDX-License-Identifier: MIT
// solhint-disable chainlink-solidity/prefix-internal-functions-with-underscore
pragma solidity 0.8.25;

import {RequestReceipt} from "src/libraries/RequestReceipt.sol";

library SafeCrossChainReceipt {
	function isSuccess(RequestReceipt.CrossChainReceiptType receiptType) internal pure returns (bool) {
		return receiptType == RequestReceipt.CrossChainReceiptType.SUCCESS;
	}

	function isFailure(RequestReceipt.CrossChainReceiptType receiptType) internal pure returns (bool) {
		return receiptType == RequestReceipt.CrossChainReceiptType.FAILURE;
	}

	function isPoolCreated(RequestReceipt.CrossChainSuccessReceiptType successReceiptType) internal pure returns (bool) {
		return successReceiptType == RequestReceipt.CrossChainSuccessReceiptType.POOL_CREATED;
	}

	function isPoolNotCreated(RequestReceipt.CrossChainFailureReceiptType failureReceiptType) internal pure returns (bool) {
		return failureReceiptType == RequestReceipt.CrossChainFailureReceiptType.POOL_CREATION_FAILED;
	}

	function isDeposited(RequestReceipt.CrossChainSuccessReceiptType successReceiptType) internal pure returns (bool) {
		return successReceiptType == RequestReceipt.CrossChainSuccessReceiptType.DEPOSITED;
	}

	function isWithdrawn(RequestReceipt.CrossChainSuccessReceiptType successReceiptType) internal pure returns (bool) {
		return successReceiptType == RequestReceipt.CrossChainSuccessReceiptType.WITHDRAW;
	}
}
