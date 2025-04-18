// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../../src/interfaces/IIntent.sol";

/**
 * @title MockIntent
 * @dev Mock implementation of the Intent contract for testing
 */
contract MockIntent is IIntent {
    // Variables to track calls
    bool private _wasCalled;
    address private _lastCaller;
    bytes private _lastMessage;

    /**
     * @dev Mock implementation of onCall function to record the parameters
     * @param context The message context containing sender information
     * @param message The encoded settlement payload
     * @return Empty bytes array
     */
    function onCall(MessageContext calldata context, bytes calldata message) external payable returns (bytes memory) {
        _wasCalled = true;
        _lastCaller = context.sender;
        _lastMessage = message;
        return "";
    }

    /**
     * @dev Check if onCall was called
     * @return Whether onCall was called
     */
    function wasCalled() external view returns (bool) {
        return _wasCalled;
    }

    /**
     * @dev Get the address of the last caller
     * @return The address of the last caller
     */
    function lastCaller() external view returns (address) {
        return _lastCaller;
    }

    /**
     * @dev Get the last message received
     * @return The last message received
     */
    function lastMessage() external view returns (bytes memory) {
        return _lastMessage;
    }
}
