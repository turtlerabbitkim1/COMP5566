// File: src/integrations/ExitQueueClaimHelper.sol
// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: 2024 Kiln <contact@kiln.fi>
//
// ██╗  ██╗██╗██╗     ███╗   ██╗
// ██║ ██╔╝██║██║     ████╗  ██║
// █████╔╝ ██║██║     ██╔██╗ ██║
// ██╔═██╗ ██║██║     ██║╚██╗██║
// ██║  ██╗██║███████╗██║ ╚████║
// ╚═╝  ╚═╝╚═╝╚══════╝╚═╝  ╚═══╝
//
pragma solidity 0.8.18;

import {IExitQueueClaimHelper} from "@src/interfaces/integrations/IExitQueueClaimHelper.sol";
import {IFeeDispatcher} from "@src/interfaces/integrations/IFeeDispatcher.sol";
import {IvExitQueue} from "@src/interfaces/IvExitQueue.sol";

/// @title ExitQueueClaimHelper (V1) Contract
/// @author gauthiermyr @ Kiln
/// @notice This contract contains functions to resolve and claim casks on several exit queues.
contract ExitQueueClaimHelper is IExitQueueClaimHelper {
    /// @inheritdoc IExitQueueClaimHelper
    function multiClaim(address[] calldata exitQueues, uint256[][] calldata ticketIds, uint32[][] calldata casksIds)
        external
        override
        returns (IvExitQueue.ClaimStatus[][] memory statuses)
    {
        if (exitQueues.length != ticketIds.length) {
            revert IFeeDispatcher.UnequalLengths(exitQueues.length, ticketIds.length);
        }
        if (exitQueues.length != casksIds.length) {
            revert IFeeDispatcher.UnequalLengths(exitQueues.length, casksIds.length);
        }

        statuses = new IvExitQueue.ClaimStatus[][](exitQueues.length);

        for (uint256 i = 0; i < exitQueues.length;) {
            IvExitQueue exitQueue = IvExitQueue(exitQueues[i]);
            // slither-disable-next-line calls-loop
            statuses[i] = exitQueue.claim(ticketIds[i], casksIds[i], type(uint16).max);

            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IExitQueueClaimHelper
    function multiResolve(address[] calldata exitQueues, uint256[][] calldata ticketIds)
        external
        view
        override
        returns (int64[][] memory caskIdsOrErrors)
    {
        if (exitQueues.length != ticketIds.length) {
            revert IFeeDispatcher.UnequalLengths(exitQueues.length, ticketIds.length);
        }

        caskIdsOrErrors = new int64[][](exitQueues.length);

        for (uint256 i = 0; i < exitQueues.length;) {
            IvExitQueue exitQueue = IvExitQueue(exitQueues[i]);
            // slither-disable-next-line calls-loop
            caskIdsOrErrors[i] = exitQueue.resolve(ticketIds[i]);

            unchecked {
                ++i;
            }
        }
    }
}


// File: src/interfaces/integrations/IExitQueueClaimHelper.sol
// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: 2024 Kiln <contact@kiln.fi>
//
// ██╗  ██╗██╗██╗     ███╗   ██╗
// ██║ ██╔╝██║██║     ████╗  ██║
// █████╔╝ ██║██║     ██╔██╗ ██║
// ██╔═██╗ ██║██║     ██║╚██╗██║
// ██║  ██╗██║███████╗██║ ╚████║
// ╚═╝  ╚═╝╚═╝╚══════╝╚═╝  ╚═══╝
//
pragma solidity 0.8.18;

import {IvExitQueue} from "@src/interfaces/IvExitQueue.sol";

/// @title ExitQueueClaimHelper (V1) Interface
/// @author gauthiermyr @ Kiln
interface IExitQueueClaimHelper {
    /// @notice Claim caskIds for given tickets on each exit queue
    /// @param exitQueues List of exit queues
    /// @param ticketIds List of tickets in each exit queue
    /// @param casksIds List of caskIds to claim with each ticket
    /// @return statuses List of claim statuses for each ticket
    function multiClaim(address[] calldata exitQueues, uint256[][] calldata ticketIds, uint32[][] calldata casksIds)
        external
        returns (IvExitQueue.ClaimStatus[][] memory statuses);

    /// @notice Resolve a list of casksIds for given exitQueues and tickets
    /// @param exitQueues List of exit queues
    /// @param ticketIds List of tickets in each exit queue
    /// @return caskIdsOrErrors List of caskIds or errors for each ticket
    function multiResolve(address[] calldata exitQueues, uint256[][] calldata ticketIds)
        external
        view
        returns (int64[][] memory caskIdsOrErrors);
}


// File: src/interfaces/integrations/IFeeDispatcher.sol
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Kiln <contact@kiln.fi>
//
// ██╗  ██╗██╗██╗     ███╗   ██╗
// ██║ ██╔╝██║██║     ████╗  ██║
// █████╔╝ ██║██║     ██╔██╗ ██║
// ██╔═██╗ ██║██║     ██║╚██╗██║
// ██║  ██╗██║███████╗██║ ╚████║
// ╚═╝  ╚═╝╚═╝╚══════╝╚═╝  ╚═══╝
//
pragma solidity 0.8.18;

/// @title FeeDispatcher (V1) Interface
/// @author 0xvv @ Kiln
/// @notice This contract contains functions to dispatch the ETH in a contract upon withdrawal.
interface IFeeDispatcher {
    /// @notice Emitted when the commission split is changed.
    /// @param recipients The addresses of recipients
    /// @param splits The percentage of each recipient in basis points
    event NewCommissionSplit(address[] recipients, uint256[] splits);

    /// @notice Emitted when the integrator withdraws ETH
    /// @param withdrawer address withdrawing the ETH
    /// @param amountWithdrawn amount of ETH withdrawn
    event CommissionWithdrawn(address indexed withdrawer, uint256 amountWithdrawn);

    /// @notice Thrown when functions are given lists of different length in batch arguments
    /// @param lengthA First argument length
    /// @param lengthB Second argument length
    error UnequalLengths(uint256 lengthA, uint256 lengthB);

    /// @notice Thrown when the recipient reverts when paid.
    /// @param recipient The recipient that reverted
    error NotPayable(address recipient);

    /// @notice Thrown when the recipient reverts when paid.
    /// @param recipient The recipient that reverted
    /// @param returnData The return data from the recipient
    error RecipientReverted(address recipient, bytes returnData);

    /// @notice Thrown when a function is called while the contract is locked
    error Reentrancy();

    /// @notice Allows the integrator to withdraw the ETH in the contract.
    function withdrawCommission() external;
}


// File: src/interfaces/IvExitQueue.sol
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Kiln <contact@kiln.fi>
//
// ██╗  ██╗██╗██╗     ███╗   ██╗
// ██║ ██╔╝██║██║     ████╗  ██║
// █████╔╝ ██║██║     ██╔██╗ ██║
// ██╔═██╗ ██║██║     ██║╚██╗██║
// ██║  ██╗██║███████╗██║ ╚████║
// ╚═╝  ╚═╝╚═╝╚══════╝╚═╝  ╚═══╝
//
pragma solidity 0.8.18;

import {IFixable} from "@src/interfaces/utils/IFixable.sol";
import {IvPoolSharesReceiver} from "@src/interfaces/IvPoolSharesReceiver.sol";
import {ctypes} from "@src/ctypes/ctypes.sol";

/// @title Exit Queue Interface
/// @author mortimr @ Kiln
/// @notice The exit queue stores exit requests until they are filled and claimable
interface IvExitQueue is IFixable, IvPoolSharesReceiver {
    enum ClaimStatus {
        CLAIMED,
        PARTIALLY_CLAIMED,
        SKIPPED
    }

    /// @notice Emitted when the stored Pool address is changed
    /// @param pool The new pool address
    event SetPool(address pool);

    /// @notice Emitted when the stored token uri image url is changed
    /// @param tokenUriImageUrl The new token uri image url
    event SetTokenUriImageUrl(string tokenUriImageUrl);

    /// @notice Emitted when the transfer enabled status is changed
    /// @param enabled The new transfer enabled status
    event SetTransferEnabled(bool enabled);

    /// @notice Emitted when the unclaimed funds buffer is changed
    /// @param unclaimedFunds The new unclaimed funds buffer
    event SetUnclaimedFunds(uint256 unclaimedFunds);

    /// @notice Emitted when ether was supplied to the vPool
    /// @param amount The amount of ETH supplied
    event SuppliedEther(uint256 amount);

    /// @notice Emitted when a ticket is created
    /// @param owner The address of the ticket owner
    /// @param idx The index of the ticket
    /// @param id The ID of the ticket
    /// @param ticket The ticket details
    event PrintedTicket(address indexed owner, uint32 idx, uint256 id, ctypes.Ticket ticket);

    /// @notice Emitted when a cask is created
    /// @param id The ID of the cask
    /// @param cask The cask details
    event ReceivedCask(uint32 id, ctypes.Cask cask);

    /// @notice Emitted when a ticket is claimed against a cask, can happen several times for the same ticket but different casks
    /// @param ticketId The ID of the ticket
    /// @param caskId The ID of the cask
    /// @param amountFilled The amount of shares filled
    /// @param amountEthFilled The amount of ETH filled
    /// @param unclaimedEth The amount of ETH that is added to the unclaimed buffer
    event FilledTicket(
        uint256 indexed ticketId, uint32 indexed caskId, uint128 amountFilled, uint256 amountEthFilled, uint256 unclaimedEth
    );

    /// @notice Emitted when a ticket is "reminted" and its external id is modified
    /// @param oldTicketId The old ID of the ticket
    /// @param newTicketId The new ID of the ticket
    /// @param ticketIndex The index of the ticket
    event TicketIdUpdated(uint256 indexed oldTicketId, uint256 indexed newTicketId, uint32 indexed ticketIndex);

    /// @notice Emitted when a payment is made after a user performed a claim
    /// @param recipient The address of the recipient
    /// @param amount The amount of ETH paid
    event Payment(address indexed recipient, uint256 amount);

    /// @notice Transfer of tickets is disabled
    error TransferDisabled();

    /// @notice The provided ticket ID is invalid
    /// @param id The ID of the ticket
    error InvalidTicketId(uint256 id);

    /// @notice The provided cask ID is invalid
    /// @param id The ID of the cask
    error InvalidCaskId(uint32 id);

    /// @notice The provided ticket IDs and cask IDs are not the same length
    error InvalidLengths();

    /// @notice The ticket and cask are not associated
    /// @param ticketId The ID of the ticket
    /// @param caskId The ID of the cask
    error TicketNotMatchingCask(uint256 ticketId, uint32 caskId);

    /// @notice The claim transfer failed
    /// @param recipient The address of the recipient
    /// @param rdata The revert data
    error ClaimTransferFailed(address recipient, bytes rdata);

    /// @notice Initializes the ExitQueue (proxy pattern)
    /// @param vpool The address of the associated vPool
    /// @param newTokenUriImageUrl The token uri image url
    function initialize(address vpool, string calldata newTokenUriImageUrl) external;

    /// @notice Adds eth and creates a new cask
    /// @dev only callbacle by the vPool
    /// @param shares The amount of shares to cover with the provided eth
    function feed(uint256 shares) external payable;

    /// @notice Pulls eth from the unclaimed eth buffer
    /// @dev Only callable by the vPool
    /// @param max The maximum amount of eth to pull
    function pull(uint256 max) external;

    /// @notice Claims the provided tickets against their associated casks
    /// @dev To retrieve the list of casks, an off-chain resolve call should be performed
    /// @param ticketIds The IDs of the tickets to claim
    /// @param caskIds The IDs of the casks to claim against
    /// @param maxClaimDepth The maximum recursion depth for the claim, 0 for unlimited
    function claim(uint256[] calldata ticketIds, uint32[] calldata caskIds, uint16 maxClaimDepth)
        external
        returns (ClaimStatus[] memory statuses);

    /// @notice Sets the token uri image inside the returned token uri
    /// @param newTokenUriImageUrl The new token uri image url
    function setTokenUriImageUrl(string calldata newTokenUriImageUrl) external;

    /// @notice Enables transfers
    /// @dev Transfers cannot be disabled once enabled
    function enableTransfers() external;

    /// @notice Returns the token uri image url
    /// @return The token uri image url
    function tokenUriImageUrl() external view returns (string memory);

    /// @notice Returns the address of the associated vPool
    /// @return The address of the associated vPool
    function pool() external view returns (address);

    /// @notice Returns the transfer enabled status
    /// @return True if transfers are enabled
    function transferEnabled() external view returns (bool);

    /// @notice Returns the unclaimed funds buffer
    /// @return The unclaimed funds buffer
    function unclaimedFunds() external view returns (uint256);

    /// @notice Returns the id of the ticket based on the index
    /// @param idx The index of the ticket
    function ticketIdAtIndex(uint32 idx) external view returns (uint256);

    /// @notice Returns the details about the ticket with the provided ID
    /// @param id The ID of the ticket
    /// @return The ticket details
    function ticket(uint256 id) external view returns (ctypes.Ticket memory);

    /// @notice Returns the number of tickets
    /// @return The number of tickets
    function ticketCount() external view returns (uint256);

    /// @notice Returns the details about the cask with the provided ID
    /// @param id The ID of the cask
    /// @return The cask details
    function cask(uint32 id) external view returns (ctypes.Cask memory);

    /// @notice Returns the number of casks
    /// @return The number of casks
    function caskCount() external view returns (uint256);

    /// @notice Resolves the provided tickets to their associated casks or provide resolution error codes
    /// @dev TICKET_ID_OUT_OF_BOUNDS = -1;
    ///      TICKET_ALREADY_CLAIMED = -2;
    ///      TICKET_PENDING = -3;
    /// @param ticketIds The IDs of the tickets to resolve
    /// @return caskIdsOrErrors The IDs of the casks or error codes
    function resolve(uint256[] memory ticketIds) external view returns (int64[] memory caskIdsOrErrors);
}


// File: src/interfaces/utils/IFixable.sol
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Kiln <contact@kiln.fi>
//
// ██╗  ██╗██╗██╗     ███╗   ██╗
// ██║ ██╔╝██║██║     ████╗  ██║
// █████╔╝ ██║██║     ██╔██╗ ██║
// ██╔═██╗ ██║██║     ██║╚██╗██║
// ██║  ██╗██║███████╗██║ ╚████║
// ╚═╝  ╚═╝╚═╝╚══════╝╚═╝  ╚═══╝
//
pragma solidity 0.8.18;

/// @title Fixable Interface
/// @author mortimr @ Kiln
/// @dev Unstructured Storage Friendly
/// @notice The Fixable contract can be used on cubs to expose a safe noop to force a fix.
interface IFixable {
    /// @notice Noop method to force a global fix to be applied.
    function fix() external;
}


// File: src/interfaces/IvPoolSharesReceiver.sol
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Kiln <contact@kiln.fi>
//
// ██╗  ██╗██╗██╗     ███╗   ██╗
// ██║ ██╔╝██║██║     ████╗  ██║
// █████╔╝ ██║██║     ██╔██╗ ██║
// ██╔═██╗ ██║██║     ██║╚██╗██║
// ██║  ██╗██║███████╗██║ ╚████║
// ╚═╝  ╚═╝╚═╝╚══════╝╚═╝  ╚═══╝
//
pragma solidity 0.8.18;

/// @title Pool Shares Receiver Interface
/// @author mortimr @ Kiln
/// @notice Interface that needs to be implemented for a contract to be able to receive shares
interface IvPoolSharesReceiver {
    /// @notice Callback used by the vPool to notify contracts of shares being transferred
    /// @param operator The address of the operator of the transfer
    /// @param from The address sending the funds
    /// @param amount The amount of shares received
    /// @param data The attached data
    /// @return selector Should return its own selector if everything went well
    function onvPoolSharesReceived(address operator, address from, uint256 amount, bytes memory data) external returns (bytes4 selector);
}


// File: src/ctypes/ctypes.sol
// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: 2024 Kiln <contact@kiln.fi>
//
// ██╗  ██╗██╗██╗     ███╗   ██╗
// ██║ ██╔╝██║██║     ████╗  ██║
// █████╔╝ ██║██║     ██╔██╗ ██║
// ██╔═██╗ ██║██║     ██║╚██╗██║
// ██║  ██╗██║███████╗██║ ╚████║
// ╚═╝  ╚═╝╚═╝╚══════╝╚═╝  ╚═══╝
//
pragma solidity 0.8.18;

/// @title Custom Types
library ctypes {
    /// @notice Structure representing the validation key registry
    /// @dev The keys are stored inside a Merkle Tree whose root is stored in the contracts
    /// @dev Alonside the root, the ipfs hash of the complete Merkle Tree is also stored
    /// @dev The tree format is composed of the concatenation of [publicKey + signature + withdrawalChannel]
    ///      separated by a newline
    /// @param root The root of the Merkle Tree
    /// @param ipfsHash The ipfs hash of the Merkle Tree content
    struct ValidationKeyRegistry {
        bytes32 root;
        string ipfsHash;
    }

    /// @notice Structure representing a deposit in the factory
    /// @param dedicatedRecipient The dedicated recipient contract of the validator. Only defined for validators of channel zero
    /// @param owner The owner of the deposited validator
    /// @param feeRecipient The fee recipient of the validator
    /// @param thresholdGwei The threshold of the deposit in gwei
    struct Deposit {
        address dedicatedRecipient;
        address owner;
        address feeRecipient;
        uint96 thresholdGwei;
    }

    /// @notice Structure representing the operator metadata in the factory
    /// @param name The name of the operator
    /// @param url The url of the operator
    /// @param iconUrl The icon url of the operator
    struct Metadata {
        string name;
        string url;
        string iconUrl;
    }

    /// @notice Structure representing the global consensus layer spec held in the global consensus layer spec holder
    /// @param genesisTimestamp The timestamp of the genesis of the consensus layer (slot 0 timestamp)
    /// @param epochsUntilFinal The number of epochs until a block is considered final by the vsuite
    /// @param slotsPerEpoch The number of slots per epoch (32 on mainnet)
    /// @param secondsPerSlot The number of seconds per slot (12 on mainnet)
    struct ConsensusLayerSpec {
        uint64 genesisTimestamp;
        uint64 epochsUntilFinal;
        uint64 slotsPerEpoch;
        uint64 secondsPerSlot;
    }

    /// @notice Structure representing the report bounds held in the pools
    /// @param maxAPRUpperBound The maximum APR upper bound, representing the maximum increase in underlying balance checked at each oracle report
    /// @param maxAPRUpperCoverageBoost The maximum APR upper coverage boost, representing the additional increase allowed when pulling coverage funds
    /// @param maxRelativeLowerBound The maximum relative lower bound, representing the maximum decrease in underlying balance checked at each oracle report
    struct ReportBounds {
        uint64 maxAPRUpperBound;
        uint64 maxAPRUpperCoverageBoost;
        uint64 maxRelativeLowerBound;
    }

    /// @notice The mode selected when constructing the vNFT contract
    /// @dev The mode defines the reward flow behavior
    /// @dev Static mode: rewards are never moved without the user triggering a withdrawal. vNFTs change their ID whenever they are claimed
    /// @dev Dynamic mode: rewards can be received automatically if enabled. vNFTs keep their ID when they are claimed. vNFTs are claimed when they are transferred
    enum vNFTMode {
        Static,
        Dynamic
    }

    /// @notice Structure representing the vNFT contract configuration
    /// @param mode The mode selected when constructing the vNFT contract
    /// @param commissionBps The commission in basis points taken by the vNFT operator
    /// @param defaultThreshold The default threshold for the vNFTs (threshold in gwei at which auto claim will happen, only in Dynamic mode)
    /// @param defaultExtraData The default extra data for the vNFTs
    /// @param metadataURIBase The base URI for the metadata of the vNFTs
    struct vNFTConfiguration {
        vNFTMode mode;
        uint16 commissionBps;
        uint96 defaultThreshold;
        string defaultExtraData;
        string metadataURIBase;
    }

    /// @notice Structure representing a vNFT validator in storage
    /// @dev Used to map the id of a token to a validator id & its exit status
    /// @param exited Whether the validator has exited
    /// @param id The validator id, given by the vFactory
    struct vNFTValidator {
        bool exited;
        uint248 id;
    }

    /// @notice Structure representing the consensus layer report submitted by oracle members
    /// @param balanceSum sum of all the balances of all validators that have been activated by the vPool
    ///        this means that as long as the validator was activated, no matter its current status, its balance is taken
    ///        into account
    ///        this value can increase and decrease based on the current state of the validators
    /// @param exitedSum sum of all the ether that has been exited by the validators that have been activated by the vPool
    ///        to compute this value, we look for withdrawal events inside the block bodies that have happened at an epoch
    ///        that is greater or equal to the withdrawable epoch of a validator purchased by the pool
    ///        when we detect any, we take min(amount,32 eth) into account as exited balance
    ///        this value can only increase over time
    /// @param skimmedSum sum of all the ether that has been skimmed by the validators that have been activated by the vPool
    ///        similar to the exitedSum, we look for withdrawal events. If the epochs is lower than the withdrawable epoch
    ///        we take into account the full withdrawal amount, otherwise we take amount - min(amount, 32 eth) into account
    ///        this value can only increase over time
    /// @param slashedSum sum of all the ether that has been slashed by the validators that have been activated by the vPool
    ///        to compute this value, we look for validators that are of have been in the slashed state
    ///        then we take the balance of the validator at the epoch prior to its slashing event
    ///        we then add the delta between this old balance and the current balance (or balance just before withdrawal)
    ///        this value can only increase over time
    /// @param exitingSum amount of currently exiting eth, that will soon hit the withdrawal recipient
    ///        this value is computed by taking the balance of any validator in the exit or slashed state or after
    ///        this value can increase and decrease based on the current state of the exiting validators
    /// @param maxExitable maximum amount that can get requested for exits during report processing
    ///        this value is determined by the oracle. its calculation logic can be updated but all members need to agree and reach
    ///        consensus on the new calculation logic. Its role is to control the rate at which exit requests are performed
    ///        setting its value to 0 will prevent requesting any validator exit and will prevent the pool from feeding the exit queue
    ///        this value can increase and decrease based on the current strategy adopted by the oracle members
    /// @param maxCommittable maximum amount that can get committed for deposits during report processing
    ///        positive value means commit happens before possible exit boosts, negative after
    ///        similar to the mexExitable, this value is determined by the oracle. its calculation logic can be updated but all
    ///        members need to agree and reach consensus on the new calculation logic. Its role is to control the rate at which
    ///        deposits are made. Committed funds are funds that are always a multiple of 32 eth and that cannot be used for
    ///        anything else than purchasing validator, as opposed to the deposited funds that can still be used to fuel the
    ///        exit queue in some cases.
    ///        this value can increase and decrease based on the current strategy adopted by the oracle members
    /// @param epoch epoch at which the report was crafter
    ///        this value can only increase over time
    /// @param activatedCount current count of validators that have been activated by the vPool
    ///        no matter the current state of the validator, if it has been activated, it has to be accounted inside this value
    ///        this value can only increase over time
    /// @param stoppedCount current count of validators that have been stopped (being in the exit queue, exited or slashed)
    ///        this value can only increase over time
    /// @param invalidActivationCount current count of validators that have been activated by the vPool but that have been
    ///        detected as invalid by the oracle members. This can happen if the signature is invalid or if there has already
    ///        been an activation for this specific public key.
    ///        this value can only increase over time
    struct ValidatorsReport {
        uint128 balanceSum;
        uint128 exitedSum;
        uint128 skimmedSum;
        uint128 slashedSum;
        uint128 exitingSum;
        uint128 maxExitable;
        int256 maxCommittable;
        uint64 epoch;
        uint32 activatedCount;
        uint32 stoppedCount;
        uint32 invalidActivationCount;
    }

    /// @notice Structure representing the ethers held in the pools
    /// @param deposited The amount of deposited ethers, that can either be used to boost exits or get committed
    /// @param committed The amount of committed ethers, that can only be used to purchase validators
    struct Ethers {
        uint128 deposited;
        uint128 committed;
    }

    /// @notice Structure representing a ticket in the exit queue
    /// @param position The position of the ticket in the exit queue (equal to the position + size of the previous ticket)
    /// @param size The size of the ticket in the exit queue (in pool shares)
    /// @param maxExitable The maximum amount of ethers that can be exited by the ticket owner (no more rewards in the exit queue, losses are still mutualized)
    struct Ticket {
        uint128 position;
        uint128 size;
        uint128 maxExitable;
    }

    /// @notice Structure representing a cask in the exit queue. This entity is created by the pool upon oracle reports, when exit liquidity is available to feed the exit queue
    /// @param position The position of the cask in the exit queue (equal to the position + size of the previous cask)
    /// @param size The size of the cask in the exit queue (in pool shares)
    /// @param value The value of the cask in the exit queue (in ethers)
    struct Cask {
        uint128 position;
        uint128 size;
        uint128 value;
    }

    // vsuite
    type ApprovalsMapping is bytes32;
    type CaskArray is bytes32;
    type ConsensusLayerSpecStruct is bytes32;
    type DepositMapping is bytes32;
    type EthersStruct is bytes32;
    type FactoryDepositorMapping is bytes32;
    type MetadataStruct is bytes32;
    type ReportBoundsStruct is bytes32;
    type TicketArray is bytes32;
    type ValidationKeyRegistryStruct is bytes32;
    type ValidatorsReportStruct is bytes32;
    type OperatorApprovalsMapping is bytes32;

    // integrations
    type BalancePerIdMapping is bytes32;
    type BalanceMapping is bytes32;
    type vNFTConfigurationStruct is bytes32;
    type vNFTValidatorMapping is bytes32;
}


