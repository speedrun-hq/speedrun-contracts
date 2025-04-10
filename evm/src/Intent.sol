// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IGateway.sol";
import "./interfaces/IRouter.sol";
import "./utils/PayloadUtils.sol";

/**
 * @title Intent
 * @dev Handles intent-based transfers across chains
 */
contract Intent is Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable {
    // Role definitions
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // Counter for generating unique intent IDs
    uint256 public intentCounter;

    // Gateway contract address
    address public gateway;

    // Router contract address on ZetaChain
    address public router;

    // Flag indicating if this contract is deployed on ZetaChain
    bool public immutable isZetaChain;

    // Mapping to track fulfillments
    mapping(bytes32 => address) public fulfillments;

    // Struct to track settlement status
    struct Settlement {
        bool settled;
        bool fulfilled;
        uint256 paidTip;
        address fulfiller;
    }

    // Mapping to track settlements
    mapping(bytes32 => Settlement) public settlements;

    // Struct for message context
    struct MessageContext {
        address sender;
    }

    // Event emitted when a new intent is created
    event IntentInitiated(
        bytes32 indexed intentId,
        address indexed asset,
        uint256 amount,
        uint256 targetChain,
        bytes receiver,
        uint256 tip,
        uint256 salt
    );

    // Event emitted when an intent is fulfilled
    event IntentFulfilled(bytes32 indexed intentId, address indexed asset, uint256 amount, address indexed receiver);

    // Event emitted when an intent is settled
    event IntentSettled(
        bytes32 indexed intentId,
        address indexed asset,
        uint256 amount,
        address indexed receiver,
        bool fulfilled,
        address fulfiller,
        uint256 actualAmount,
        uint256 paidTip
    );

    // Event emitted when the gateway is updated
    event GatewayUpdated(address indexed oldGateway, address indexed newGateway);

    // Event emitted when the router is updated
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(bool _isZetaChain) {
        isZetaChain = _isZetaChain;
        _disableInitializers();
    }

    /**
     * @dev Pauses all contract functions that use the whenNotPaused modifier
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpauses all contract functions
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // Modifier to restrict function access to gateway only
    modifier onlyGateway() {
        require(msg.sender == gateway, "Only gateway can call this function");
        _;
    }

    function initialize(address _gateway, address _router) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Pausable_init();

        // Set up admin role
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);

        gateway = _gateway;
        router = _router;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @dev Computes a unique intent ID
     * @param counter The current intent counter
     * @param salt Random salt for uniqueness
     * @param chainId The chain ID where the intent is being initiated
     * @return The computed intent ID
     */
    function computeIntentId(uint256 counter, uint256 salt, uint256 chainId) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(counter, salt, chainId));
    }

    /**
     * @dev Get the next intent ID that would be generated with the current counter
     * @param salt Random salt for uniqueness
     * @return The next intent ID that would be generated
     */
    function getNextIntentId(uint256 salt) public view returns (bytes32) {
        return computeIntentId(intentCounter, salt, block.chainid);
    }

    /**
     * @dev Calculates the fulfillment index for the given parameters
     * @param intentId The ID of the intent
     * @param asset The ERC20 token address
     * @param amount Amount to transfer
     * @param receiver Receiver address
     * @return The computed fulfillment index
     */
    function getFulfillmentIndex(bytes32 intentId, address asset, uint256 amount, address receiver)
        public
        pure
        returns (bytes32)
    {
        return PayloadUtils.computeFulfillmentIndex(intentId, asset, amount, receiver);
    }

    /**
     * @dev Initiates a new intent for cross-chain transfer
     * @param asset The ERC20 token address
     * @param amount Amount to receive on target chain
     * @param targetChain Target chain ID
     * @param receiver Receiver address in bytes format
     * @param tip Tip for the fulfiller
     * @param salt Salt for intent ID generation
     * @return intentId The generated intent ID
     */
    function initiate(
        address asset,
        uint256 amount,
        uint256 targetChain,
        bytes calldata receiver,
        uint256 tip,
        uint256 salt
    ) external whenNotPaused returns (bytes32) {
        // Cannot initiate a transfer to the current chain
        require(targetChain != block.chainid, "Target chain cannot be the current chain");

        // Calculate total amount to transfer (amount + tip)
        uint256 totalAmount = amount + tip;

        // Transfer ERC20 tokens from sender to this contract
        IERC20(asset).transferFrom(msg.sender, address(this), totalAmount);

        // Generate intent ID using the computeIntentId function with current chain ID
        bytes32 intentId = computeIntentId(intentCounter, salt, block.chainid);

        // Increment counter
        intentCounter++;

        // Create payload for crosschain transaction
        bytes memory payload = PayloadUtils.encodeIntentPayload(intentId, amount, tip, targetChain, receiver);

        if (isZetaChain) {
            // ZetaChain as source - direct call to router without going through gateway
            _initiateFromZetaChain(asset, totalAmount, payload);
        } else {
            // Non-ZetaChain source - use gateway
            _initiateFromConnectedChain(asset, totalAmount, payload);
        }

        // Emit event
        emit IntentInitiated(intentId, asset, amount, targetChain, receiver, tip, salt);

        return intentId;
    }

    /**
     * @dev Internal function for initiating intent from ZetaChain
     * @param asset The ERC20 token address (ZRC20)
     * @param totalAmount Total amount to transfer
     * @param payload The encoded intent payload
     */
    function _initiateFromZetaChain(address asset, uint256 totalAmount, bytes memory payload) internal {
        // Approve router to spend the tokens
        IERC20(asset).approve(router, totalAmount);

        // Create ZetaChain message context
        IGateway.ZetaChainMessageContext memory context = IGateway.ZetaChainMessageContext({
            sender: abi.encodePacked(address(this)),
            senderEVM: address(this),
            chainID: block.chainid
        });

        // Call router directly
        IRouter(router).onCall(context, asset, totalAmount, payload);
    }

    /**
     * @dev Internal function for initiating intent from connected (non-ZetaChain) networks
     * @param asset The ERC20 token address
     * @param totalAmount Total amount to transfer
     * @param payload The encoded intent payload
     */
    function _initiateFromConnectedChain(address asset, uint256 totalAmount, bytes memory payload) internal {
        // Approve gateway to spend the tokens
        IERC20(asset).approve(gateway, totalAmount);

        // Create revert options
        IGateway.RevertOptions memory revertOptions = IGateway.RevertOptions({
            revertAddress: msg.sender, // in case of revert, the funds are directly sent back to the sender
            callOnRevert: false,
            abortAddress: address(0),
            revertMessage: "",
            onRevertGasLimit: 0
        });

        // Call gateway to initiate crosschain transaction
        IGateway(gateway).depositAndCall(
            router, // receiver is the router on ZetaChain
            totalAmount, // transfer amount + tip
            asset,
            payload,
            revertOptions
        );
    }

    /**
     * @dev Fulfills an intent by transferring tokens to the receiver
     * @param intentId The ID of the intent to fulfill
     * @param asset The ERC20 token address
     * @param amount Amount to transfer
     * @param receiver Receiver address
     */
    function fulfill(bytes32 intentId, address asset, uint256 amount, address receiver) external whenNotPaused {
        // Compute the fulfillment index
        bytes32 fulfillmentIndex = PayloadUtils.computeFulfillmentIndex(intentId, asset, amount, receiver);

        // Check if intent is already fulfilled with these parameters
        require(fulfillments[fulfillmentIndex] == address(0), "Intent already fulfilled with these parameters");

        // Check if intent has already been settled
        require(!settlements[fulfillmentIndex].settled, "Intent already settled");

        // Transfer tokens from the sender to the receiver
        IERC20(asset).transferFrom(msg.sender, receiver, amount);

        // Register the fulfillment
        fulfillments[fulfillmentIndex] = msg.sender;

        // Emit event
        emit IntentFulfilled(intentId, asset, amount, receiver);
    }

    /**
     * @dev Internal function to settle an intent
     * @param intentId The ID of the intent to settle
     * @param asset The ERC20 token address
     * @param amount Amount for intent index computation
     * @param receiver Receiver address
     * @param tip Tip for the fulfiller
     * @param actualAmount Actual amount to transfer after fees
     * @return fulfilled Whether the intent was fulfilled
     */
    function _settle(
        bytes32 intentId,
        address asset,
        uint256 amount,
        address receiver,
        uint256 tip,
        uint256 actualAmount
    ) internal returns (bool) {
        // Compute the fulfillment index using the original amount
        bytes32 fulfillmentIndex = PayloadUtils.computeFulfillmentIndex(intentId, asset, amount, receiver);

        // Check if intent has already been settled
        require(!settlements[fulfillmentIndex].settled, "Intent already settled");

        // Get the fulfiller if it exists
        address fulfiller = fulfillments[fulfillmentIndex];
        bool fulfilled = fulfiller != address(0);

        // Create settlement record
        Settlement storage settlement = settlements[fulfillmentIndex];
        settlement.settled = true;
        settlement.fulfilled = fulfilled;
        settlement.fulfiller = fulfiller;

        // Set paid tip
        uint256 paidTip = 0;

        // If there's a fulfiller, transfer the actual amount + tip to them
        // Otherwise, transfer actual amount + tip to the receiver
        if (fulfilled) {
            IERC20(asset).transfer(fulfiller, actualAmount + tip);
            settlement.paidTip = tip;
            paidTip = tip;
        } else {
            IERC20(asset).transfer(receiver, actualAmount + tip);
        }

        // Emit the IntentSettled event
        emit IntentSettled(intentId, asset, amount, receiver, fulfilled, fulfiller, actualAmount, paidTip);

        return fulfilled;
    }

    /**
     * @dev Handles incoming cross-chain messages
     * @param context Message context containing sender information
     * @param message Encoded settlement payload
     * @return Empty bytes array
     */
    function onCall(MessageContext calldata context, bytes calldata message)
        external
        payable
        onlyGateway
        returns (bytes memory)
    {
        // Verify sender is the router
        require(context.sender == router, "Invalid sender");

        // Decode settlement payload
        PayloadUtils.SettlementPayload memory payload = PayloadUtils.decodeSettlementPayload(message);

        // Transfer tokens from gateway to this contract
        uint256 totalTransfer = payload.actualAmount + payload.tip;
        IERC20(payload.asset).transferFrom(gateway, address(this), totalTransfer);

        // Settle the intent
        _settle(payload.intentId, payload.asset, payload.amount, payload.receiver, payload.tip, payload.actualAmount);

        return "";
    }

    /**
     * @dev Updates the gateway address
     * @param _gateway New gateway address
     */
    function updateGateway(address _gateway) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_gateway != address(0), "Gateway cannot be zero address");
        address oldGateway = gateway;
        gateway = _gateway;
        emit GatewayUpdated(oldGateway, _gateway);
    }

    /**
     * @dev Updates the router address
     * @param _router New router address
     */
    function updateRouter(address _router) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_router != address(0), "Router cannot be zero address");
        address oldRouter = router;
        router = _router;
        emit RouterUpdated(oldRouter, _router);
    }
}
