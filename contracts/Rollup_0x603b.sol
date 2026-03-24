// File: lib/l1-contracts/src/core/Rollup.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {
  IRollup,
  IHaveVersion,
  ChainTips,
  PublicInputArgs,
  L1FeeData,
  ManaBaseFeeComponents,
  FeeAssetPerEthE9,
  BlockHeaderValidationFlags,
  FeeHeader,
  RollupConfigInput
} from "@aztec/core/interfaces/IRollup.sol";
import {IStaking, AttesterConfig, Exit, AttesterView, Status} from "@aztec/core/interfaces/IStaking.sol";
import {IValidatorSelection, IEmperor} from "@aztec/core/interfaces/IValidatorSelection.sol";
import {IVerifier} from "@aztec/core/interfaces/IVerifier.sol";
import {TempBlockLog, BlockLog} from "@aztec/core/libraries/compressed-data/BlockLog.sol";
import {FeeLib, FeeHeaderLib, FeeAssetValue, PriceLib} from "@aztec/core/libraries/rollup/FeeLib.sol";
import {ProposedHeader} from "@aztec/core/libraries/rollup/ProposedHeaderLib.sol";
import {StakingLib} from "@aztec/core/libraries/rollup/StakingLib.sol";
import {GSE} from "@aztec/governance/GSE.sol";
import {IRewardDistributor} from "@aztec/governance/interfaces/IRewardDistributor.sol";
import {CompressedSlot, CompressedTimestamp, CompressedTimeMath} from "@aztec/shared/libraries/CompressedTimeMath.sol";
import {Signature} from "@aztec/shared/libraries/SignatureLib.sol";
import {ChainTipsLib, CompressedChainTips} from "./libraries/compressed-data/Tips.sol";
import {ProposeLib, ValidateHeaderArgs} from "./libraries/rollup/ProposeLib.sol";
import {RewardLib, RewardConfig} from "./libraries/rollup/RewardLib.sol";
import {DepositArgs} from "./libraries/StakingQueue.sol";
import {
  RollupCore,
  GenesisState,
  IFeeJuicePortal,
  IERC20,
  TimeLib,
  Slot,
  Epoch,
  Timestamp,
  CommitteeAttestations,
  RollupOperationsExtLib,
  ValidatorOperationsExtLib,
  EthValue,
  STFLib,
  RollupStore,
  IInbox,
  IOutbox
} from "./RollupCore.sol";

/**
 * @title Rollup
 * @author Aztec Labs
 * @notice A wrapper contract around the RollupCore which provides additional view functions
 *         which are not needed by the rollup itself to function, but makes it easy to reason
 *         about the state of the rollup and test it.
 */
contract Rollup is IStaking, IValidatorSelection, IRollup, RollupCore {
  using TimeLib for Timestamp;
  using TimeLib for Slot;
  using TimeLib for Epoch;
  using PriceLib for EthValue;
  using CompressedTimeMath for CompressedSlot;
  using CompressedTimeMath for CompressedTimestamp;
  using ChainTipsLib for CompressedChainTips;

  constructor(
    IERC20 _feeAsset,
    IERC20 _stakingAsset,
    GSE _gse,
    IVerifier _epochProofVerifier,
    address _governance,
    GenesisState memory _genesisState,
    RollupConfigInput memory _config
  ) RollupCore(_feeAsset, _stakingAsset, _gse, _epochProofVerifier, _governance, _genesisState, _config) {}

  /**
   * @notice  Validate a header for submission
   *
   * @dev     This is a convenience function that can be used by the sequencer to validate a "partial" header
   *
   * @param _header - The header to validate
   * @param _attestations - The attestations to validate
   * @param _digest - The digest to validate
   * @param _blobsHash - The blobs hash for this block
   * @param _flags - The flags to validate
   */
  function validateHeaderWithAttestations(
    ProposedHeader calldata _header,
    CommitteeAttestations memory _attestations,
    address[] calldata _signers,
    Signature memory _attestationsAndSignersSignature,
    bytes32 _digest,
    bytes32 _blobsHash,
    BlockHeaderValidationFlags memory _flags
  ) external override(IRollup) {
    Timestamp currentTime = Timestamp.wrap(block.timestamp);
    RollupOperationsExtLib.validateHeaderWithAttestations(
      ValidateHeaderArgs({
        header: _header,
        digest: _digest,
        manaBaseFee: getManaBaseFeeAt(currentTime, true),
        blobsHashesCommitment: _blobsHash,
        flags: _flags
      }),
      _attestations,
      _signers,
      _attestationsAndSignersSignature
    );
  }

  /**
   * @notice  Get the validator set for the current epoch
   * @return The validator set for the current epoch
   */
  function getCurrentEpochCommittee() external override(IValidatorSelection) returns (address[] memory) {
    return getEpochCommittee(getCurrentEpoch());
  }

  /**
   * @notice  Get the committee for a given timestamp
   *
   * @param _ts - The timestamp to get the committee for
   *
   * @return The committee for the given timestamp
   */
  function getCommitteeAt(Timestamp _ts) external override(IValidatorSelection) returns (address[] memory) {
    return getEpochCommittee(getEpochAt(_ts));
  }

  /**
   * @notice Get the committee commitment a the given timestamp
   *
   * @param _ts - The timestamp to get the committee for
   *
   * @return The committee commitment for the given timestamp
   * @return The committee size for the given timestamp
   */
  function getCommitteeCommitmentAt(Timestamp _ts) external override(IValidatorSelection) returns (bytes32, uint256) {
    return ValidatorOperationsExtLib.getCommitteeCommitmentAt(getEpochAt(_ts));
  }

  /**
   * @notice Get the committee commitment a the given epoch
   *
   * @param _epoch - The epoch to get the committee for
   *
   * @return The committee commitment for the given epoch
   * @return The committee size for the given epoch
   */
  function getEpochCommitteeCommitment(Epoch _epoch) external override(IValidatorSelection) returns (bytes32, uint256) {
    return ValidatorOperationsExtLib.getCommitteeCommitmentAt(_epoch);
  }

  /**
   * @notice  Get the proposer for the current slot
   *
   * @dev     Calls `getCurrentProposer(uint256)` with the current timestamp
   *
   * @return The address of the proposer
   */
  function getCurrentProposer() external override(IEmperor) returns (address) {
    return getProposerAt(Timestamp.wrap(block.timestamp));
  }

  /**
   * @notice  Check if msg.sender can propose at a given time
   *
   * @param _ts - The timestamp to check
   * @param _archive - The archive to check (should be the latest archive)
   * @param _who - The address to check
   *
   * @return uint256 - The slot at the given timestamp
   * @return uint256 - The block number at the given timestamp
   */
  function canProposeAtTime(Timestamp _ts, bytes32 _archive, address _who)
    external
    override(IRollup)
    returns (Slot, uint256)
  {
    return ValidatorOperationsExtLib.canProposeAtTime(_ts, _archive, _who);
  }

  function getTargetCommitteeSize() external view override(IValidatorSelection) returns (uint256) {
    return ValidatorOperationsExtLib.getTargetCommitteeSize();
  }

  function getGenesisTime() external view override(IValidatorSelection) returns (Timestamp) {
    return Timestamp.wrap(TimeLib.getStorage().genesisTime);
  }

  function getSlotDuration() external view override(IValidatorSelection) returns (uint256) {
    return TimeLib.getStorage().slotDuration;
  }

  function getEpochDuration() external view override(IValidatorSelection) returns (uint256) {
    return TimeLib.getStorage().epochDuration;
  }

  function getProofSubmissionEpochs() external view override(IRollup) returns (uint256) {
    return TimeLib.getStorage().proofSubmissionEpochs;
  }

  function getSlasher() external view override(IStaking) returns (address) {
    return StakingLib.getStorage().slasher;
  }

  function getLocalEjectionThreshold() external view override(IStaking) returns (uint256) {
    return StakingLib.getStorage().localEjectionThreshold;
  }

  function getStakingAsset() external view override(IStaking) returns (IERC20) {
    return StakingLib.getStorage().stakingAsset;
  }

  function getEjectionThreshold() external view override(IStaking) returns (uint256) {
    return StakingLib.getStorage().gse.EJECTION_THRESHOLD();
  }

  function getActivationThreshold() external view override(IStaking) returns (uint256) {
    return StakingLib.getStorage().gse.ACTIVATION_THRESHOLD();
  }

  function getExitDelay() external view override(IStaking) returns (Timestamp) {
    return StakingLib.getStorage().exitDelay.decompress();
  }

  function getGSE() external view override(IStaking) returns (GSE) {
    return StakingLib.getStorage().gse;
  }

  function getManaTarget() external view override(IRollup) returns (uint256) {
    return FeeLib.getManaTarget();
  }

  function getManaLimit() external view override(IRollup) returns (uint256) {
    return FeeLib.getManaLimit();
  }

  function getTips() external view override(IRollup) returns (ChainTips memory) {
    return ChainTipsLib.decompress(STFLib.getStorage().tips);
  }

  function status(uint256 _myHeaderBlockNumber)
    external
    view
    override(IRollup)
    returns (
      uint256 provenBlockNumber,
      bytes32 provenArchive,
      uint256 pendingBlockNumber,
      bytes32 pendingArchive,
      bytes32 archiveOfMyBlock,
      Epoch provenEpochNumber
    )
  {
    RollupStore storage rollupStore = STFLib.getStorage();
    ChainTips memory tips = ChainTipsLib.decompress(rollupStore.tips);

    return (
      tips.provenBlockNumber,
      rollupStore.archives[tips.provenBlockNumber],
      tips.pendingBlockNumber,
      rollupStore.archives[tips.pendingBlockNumber],
      archiveAt(_myHeaderBlockNumber),
      getEpochForBlock(tips.provenBlockNumber)
    );
  }

  /**
   * @notice Returns the computed public inputs for the given epoch proof.
   *
   * @dev Useful for debugging and testing. Allows submitter to compare their
   * own public inputs used for generating the proof vs the ones assembled
   * by this contract when verifying it.
   *
   * @param  _start - The start of the epoch (inclusive)
   * @param  _end - The end of the epoch (inclusive)
   * @param  _args - Array of public inputs to the proof (previousArchive, endArchive, endTimestamp, outHash, proverId)
   * @param  _fees - Array of recipient-value pairs with fees to be distributed for the epoch
   */
  function getEpochProofPublicInputs(
    uint256 _start,
    uint256 _end,
    PublicInputArgs calldata _args,
    bytes32[] calldata _fees,
    bytes calldata _blobPublicInputs
  ) external view override(IRollup) returns (bytes32[] memory) {
    return RollupOperationsExtLib.getEpochProofPublicInputs(_start, _end, _args, _fees, _blobPublicInputs);
  }

  /**
   * @notice  Validate blob transactions against given inputs.
   * @dev     Only exists here for gas estimation.
   */
  function validateBlobs(bytes calldata _blobsInput)
    external
    view
    override(IRollup)
    returns (bytes32[] memory, bytes32, bytes[] memory)
  {
    return RollupOperationsExtLib.validateBlobs(_blobsInput, checkBlob);
  }

  /**
   * @notice  Get the current archive root
   *
   * @return bytes32 - The current archive root
   */
  function archive() external view override(IRollup) returns (bytes32) {
    RollupStore storage rollupStore = STFLib.getStorage();
    return rollupStore.archives[rollupStore.tips.getPendingBlockNumber()];
  }

  function getProvenBlockNumber() external view override(IRollup) returns (uint256) {
    return STFLib.getStorage().tips.getProvenBlockNumber();
  }

  function getPendingBlockNumber() external view override(IRollup) returns (uint256) {
    return STFLib.getStorage().tips.getPendingBlockNumber();
  }

  function getBlock(uint256 _blockNumber) external view override(IRollup) returns (BlockLog memory) {
    TempBlockLog memory tempBlockLog = STFLib.getTempBlockLog(_blockNumber);
    return BlockLog({
      archive: STFLib.getStorage().archives[_blockNumber],
      headerHash: tempBlockLog.headerHash,
      blobCommitmentsHash: tempBlockLog.blobCommitmentsHash,
      attestationsHash: tempBlockLog.attestationsHash,
      payloadDigest: tempBlockLog.payloadDigest,
      slotNumber: tempBlockLog.slotNumber,
      feeHeader: tempBlockLog.feeHeader
    });
  }

  function getFeeHeader(uint256 _blockNumber) external view override(IRollup) returns (FeeHeader memory) {
    return FeeHeaderLib.decompress(STFLib.getFeeHeader(_blockNumber));
  }

  function getBlobCommitmentsHash(uint256 _blockNumber) external view override(IRollup) returns (bytes32) {
    return STFLib.getBlobCommitmentsHash(_blockNumber);
  }

  function getCurrentBlobCommitmentsHash() external view override(IRollup) returns (bytes32) {
    RollupStore storage rollupStore = STFLib.getStorage();
    return STFLib.getBlobCommitmentsHash(rollupStore.tips.getPendingBlockNumber());
  }

  function getConfig(address _attester) external view override(IStaking) returns (AttesterConfig memory) {
    return StakingLib.getConfig(_attester);
  }

  function getExit(address _attester) external view override(IStaking) returns (Exit memory) {
    return StakingLib.getExit(_attester);
  }

  function getStatus(address _attester) external view override(IStaking) returns (Status) {
    return StakingLib.getStatus(_attester);
  }

  function getAttesterView(address _attester) external view override(IStaking) returns (AttesterView memory) {
    return StakingLib.getAttesterView(_attester);
  }

  function getSharesFor(address _prover) external view override(IRollup) returns (uint256) {
    return RewardLib.getSharesFor(_prover);
  }

  /**
   * @notice  Get the sample seed for a given timestamp
   *
   * @param _ts - The timestamp to get the sample seed for
   *
   * @return The sample seed for the given timestamp
   */
  function getSampleSeedAt(Timestamp _ts) external view override(IValidatorSelection) returns (uint256) {
    return ValidatorOperationsExtLib.getSampleSeedAt(getEpochAt(_ts));
  }

  function getSamplingSizeAt(Timestamp _ts) external view override(IValidatorSelection) returns (uint256) {
    return ValidatorOperationsExtLib.getSamplingSizeAt(getEpochAt(_ts));
  }

  function getLagInEpochs() external view override(IValidatorSelection) returns (uint256) {
    return ValidatorOperationsExtLib.getLagInEpochs();
  }

  /**
   * @notice  Get the sample seed for the current epoch
   *
   * @return The sample seed for the current epoch
   */
  function getCurrentSampleSeed() external view override(IValidatorSelection) returns (uint256) {
    return ValidatorOperationsExtLib.getSampleSeedAt(getCurrentEpoch());
  }

  /**
   * @notice  Get the current slot number
   *
   * @return The current slot number
   */
  function getCurrentSlot() external view override(IEmperor) returns (Slot) {
    return Timestamp.wrap(block.timestamp).slotFromTimestamp();
  }

  /**
   * @notice  Get the timestamp for a given slot
   *
   * @param _slotNumber - The slot number to get the timestamp for
   *
   * @return The timestamp for the given slot
   */
  function getTimestampForSlot(Slot _slotNumber) external view override(IValidatorSelection) returns (Timestamp) {
    return _slotNumber.toTimestamp();
  }

  /**
   * @notice  Computes the slot at a specific time
   *
   * @param _ts - The timestamp to compute the slot for
   *
   * @return The computed slot
   */
  function getSlotAt(Timestamp _ts) external view override(IValidatorSelection) returns (Slot) {
    return _ts.slotFromTimestamp();
  }

  /**
   * @notice  Computes the epoch at a specific slot
   *
   * @param _slotNumber - The slot number to compute the epoch for
   *
   * @return The computed epoch
   */
  function getEpochAtSlot(Slot _slotNumber) external view override(IValidatorSelection) returns (Epoch) {
    return _slotNumber.epochFromSlot();
  }

  function getSequencerRewards(address _sequencer) external view override(IRollup) returns (uint256) {
    return RewardLib.getSequencerRewards(_sequencer);
  }

  function getCollectiveProverRewardsForEpoch(Epoch _epoch) external view override(IRollup) returns (uint256) {
    return RewardLib.getCollectiveProverRewardsForEpoch(_epoch);
  }

  /**
   * @notice  Get the rewards for a specific prover for a given epoch
   *          BEWARE! If the epoch is not past its deadline, this value is the "current" value
   *          and could change if a provers proves a longer series of blocks.
   *
   * @param _epoch - The epoch to get the rewards for
   * @param _prover - The prover to get the rewards for
   *
   * @return The rewards for the specific prover for the given epoch
   */
  function getSpecificProverRewardsForEpoch(Epoch _epoch, address _prover)
    external
    view
    override(IRollup)
    returns (uint256)
  {
    return RewardLib.getSpecificProverRewardsForEpoch(_epoch, _prover);
  }

  function getHasSubmitted(Epoch _epoch, uint256 _length, address _prover)
    external
    view
    override(IRollup)
    returns (bool)
  {
    return RewardLib.getHasSubmitted(_epoch, _length, _prover);
  }

  function getHasClaimed(address _prover, Epoch _epoch) external view override(IRollup) returns (bool) {
    return RewardLib.getHasClaimed(_prover, _epoch);
  }

  function getProvingCostPerManaInEth() external view override(IRollup) returns (EthValue) {
    return FeeLib.getProvingCostPerMana();
  }

  function getProvingCostPerManaInFeeAsset() external view override(IRollup) returns (FeeAssetValue) {
    return FeeLib.getProvingCostPerMana().toFeeAsset(getFeeAssetPerEth());
  }

  function getVersion() external view override(IHaveVersion) returns (uint256) {
    return STFLib.getStorage().config.version;
  }

  function getInbox() external view override(IRollup) returns (IInbox) {
    return STFLib.getStorage().config.inbox;
  }

  function getOutbox() external view override(IRollup) returns (IOutbox) {
    return STFLib.getStorage().config.outbox;
  }

  function getFeeAsset() external view override(IRollup) returns (IERC20) {
    return STFLib.getStorage().config.feeAsset;
  }

  function getFeeAssetPortal() external view override(IRollup) returns (IFeeJuicePortal) {
    return STFLib.getStorage().config.feeAssetPortal;
  }

  function getRewardDistributor() external view override(IRollup) returns (IRewardDistributor) {
    return RewardLib.getStorage().config.rewardDistributor;
  }

  function getL1FeesAt(Timestamp _timestamp) external view override(IRollup) returns (L1FeeData memory) {
    return FeeLib.getL1FeesAt(_timestamp);
  }

  function canPruneAtTime(Timestamp _ts) external view override(IRollup) returns (bool) {
    return STFLib.canPruneAtTime(_ts);
  }

  function getRewardConfig() external view override(IRollup) returns (RewardConfig memory) {
    return RewardLib.getStorage().config;
  }

  function getBlockReward() external view override(IRollup) returns (uint256) {
    return RewardLib.getBlockReward();
  }

  function isRewardsClaimable() external view override(IRollup) returns (bool) {
    return RewardLib.isRewardsClaimable();
  }

  function getEarliestRewardsClaimableTimestamp() external view override(IRollup) returns (Timestamp) {
    return RewardLib.getEarliestRewardsClaimableTimestamp();
  }

  function getAvailableValidatorFlushes() external view override(IStaking) returns (uint256) {
    return ValidatorOperationsExtLib.getAvailableValidatorFlushes();
  }

  function getIsBootstrapped() external view override(IStaking) returns (bool) {
    return StakingLib.getStorage().isBootstrapped;
  }

  function getEntryQueueAt(uint256 _index) external view override(IStaking) returns (DepositArgs memory) {
    return StakingLib.getEntryQueueAt(_index);
  }

  function getBurnAddress() external pure override(IRollup) returns (address) {
    return RewardLib.BURN_ADDRESS;
  }

  /**
   * @notice  Get the validator set for a given epoch
   *
   * @dev     Consider removing this to replace with a `size` and individual getter.
   *
   * @param _epoch The epoch number to get the validator set for
   *
   * @return The validator set for the given epoch
   */
  function getEpochCommittee(Epoch _epoch) public override(IValidatorSelection) returns (address[] memory) {
    return ValidatorOperationsExtLib.getCommitteeAt(_epoch);
  }

  /**
   * @notice  Get the proposer for the slot at a specific timestamp
   *
   * @dev     This function is very useful for off-chain usage, as it easily allow a client to
   *          determine who will be the proposer at the NEXT ethereum block.
   *          Should not be trusted when moving beyond the current epoch, since changes to the
   *          validator set might not be reflected when we actually reach that epoch (more changes
   *          might have happened).
   *
   * @dev     The proposer is selected from the validator set of the current epoch.
   *
   * @dev     Should only be access on-chain if epoch is setup, otherwise very expensive.
   *
   * @dev     A return value of address(0) means that the proposer is "open" and can be anyone.
   *
   * @dev     If the current epoch is the first epoch, returns address(0)
   *          If the current epoch is setup, we will return the proposer for the current slot
   *          If the current epoch is not setup, we will perform a sample as if it was (gas heavy)
   *
   * @return The address of the proposer
   */
  function getProposerAt(Timestamp _ts) public override(IValidatorSelection) returns (address) {
    return ValidatorOperationsExtLib.getProposerAt(_ts.slotFromTimestamp());
  }

  /**
   * @notice  Get the attester at an index
   *
   * @param _index - The index to get the attester for
   *
   * @return The attester at the index
   */
  function getAttesterAtIndex(uint256 _index) public view override(IStaking) returns (address) {
    return StakingLib.getAttesterAtIndex(_index);
  }

  /**
   * @notice  Gets the mana base fee
   *
   * @param _inFeeAsset - Whether to return the fee in the fee asset or ETH
   *
   * @return The mana base fee
   */
  function getManaBaseFeeAt(Timestamp _timestamp, bool _inFeeAsset) public view override(IRollup) returns (uint256) {
    return FeeLib.summedBaseFee(getManaBaseFeeComponentsAt(_timestamp, _inFeeAsset));
  }

  function getManaBaseFeeComponentsAt(Timestamp _timestamp, bool _inFeeAsset)
    public
    view
    override(IRollup)
    returns (ManaBaseFeeComponents memory)
  {
    return ProposeLib.getManaBaseFeeComponentsAt(_timestamp, _inFeeAsset);
  }

  /**
   * @notice  Gets the fee asset price as fee_asset / eth with 1e9 precision
   *
   * @return The fee asset price
   */
  function getFeeAssetPerEth() public view override(IRollup) returns (FeeAssetPerEthE9) {
    return FeeLib.getFeeAssetPerEthAtBlock(STFLib.getStorage().tips.getPendingBlockNumber());
  }

  function getEpochForBlock(uint256 _blockNumber) public view override(IRollup) returns (Epoch) {
    return STFLib.getEpochForBlock(_blockNumber);
  }

  /**
   * @notice  Get the archive root of a specific block
   *
   * @param _blockNumber - The block number to get the archive root of
   *
   * @return bytes32 - The archive root of the block
   */
  function archiveAt(uint256 _blockNumber) public view override(IRollup) returns (bytes32) {
    RollupStore storage rollupStore = STFLib.getStorage();
    return _blockNumber <= rollupStore.tips.getPendingBlockNumber() ? rollupStore.archives[_blockNumber] : bytes32(0);
  }

  /**
   * @notice  Computes the epoch at a specific time
   *
   * @param _ts - The timestamp to compute the epoch for
   *
   * @return The computed epoch
   */
  function getEpochAt(Timestamp _ts) public view override(IValidatorSelection) returns (Epoch) {
    return _ts.epochFromTimestamp();
  }

  /**
   * @notice  Get the current epoch number
   *
   * @return The current epoch number
   */
  function getCurrentEpoch() public view override(IValidatorSelection) returns (Epoch) {
    return Timestamp.wrap(block.timestamp).epochFromTimestamp();
  }

  function getNextFlushableEpoch() public view override(IStaking) returns (Epoch) {
    return StakingLib.getNextFlushableEpoch();
  }

  function getEntryQueueLength() public view override(IStaking) returns (uint256) {
    return StakingLib.getEntryQueueLength();
  }
}


// File: lib/l1-contracts/src/core/interfaces/IRollup.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {IFeeJuicePortal} from "@aztec/core/interfaces/IFeeJuicePortal.sol";
import {SlasherFlavor} from "@aztec/core/interfaces/ISlasher.sol";
import {IVerifier} from "@aztec/core/interfaces/IVerifier.sol";
import {IInbox} from "@aztec/core/interfaces/messagebridge/IInbox.sol";
import {IOutbox} from "@aztec/core/interfaces/messagebridge/IOutbox.sol";
import {BlockLog, CompressedTempBlockLog} from "@aztec/core/libraries/compressed-data/BlockLog.sol";
import {StakingQueueConfig} from "@aztec/core/libraries/compressed-data/StakingQueueConfig.sol";
import {CompressedChainTips, ChainTips} from "@aztec/core/libraries/compressed-data/Tips.sol";
import {CommitteeAttestations} from "@aztec/core/libraries/rollup/AttestationLib.sol";
import {FeeHeader, L1FeeData, ManaBaseFeeComponents} from "@aztec/core/libraries/rollup/FeeLib.sol";
import {FeeAssetPerEthE9, EthValue, FeeAssetValue} from "@aztec/core/libraries/rollup/FeeLib.sol";
import {ProposedHeader} from "@aztec/core/libraries/rollup/ProposedHeaderLib.sol";
import {ProposeArgs} from "@aztec/core/libraries/rollup/ProposeLib.sol";
import {RewardConfig} from "@aztec/core/libraries/rollup/RewardLib.sol";
import {RewardBoostConfig} from "@aztec/core/reward-boost/RewardBooster.sol";
import {IHaveVersion} from "@aztec/governance/interfaces/IRegistry.sol";
import {IRewardDistributor} from "@aztec/governance/interfaces/IRewardDistributor.sol";
import {Signature} from "@aztec/shared/libraries/SignatureLib.sol";
import {Timestamp, Slot, Epoch} from "@aztec/shared/libraries/TimeMath.sol";
import {IERC20} from "@oz/token/ERC20/IERC20.sol";

struct PublicInputArgs {
  bytes32 previousArchive;
  bytes32 endArchive;
  address proverId;
}

struct SubmitEpochRootProofArgs {
  uint256 start; // inclusive
  uint256 end; // inclusive
  PublicInputArgs args;
  bytes32[] fees;
  CommitteeAttestations attestations; // attestations for the last block in epoch
  bytes blobInputs;
  bytes proof;
}

/**
 * @notice Struct for storing flags for block header validation
 * @param ignoreDA - True will ignore DA check, otherwise checks
 */
struct BlockHeaderValidationFlags {
  bool ignoreDA;
}

struct GenesisState {
  bytes32 vkTreeRoot;
  bytes32 protocolContractTreeRoot;
  bytes32 genesisArchiveRoot;
}

struct RollupConfigInput {
  uint256 aztecSlotDuration;
  uint256 aztecEpochDuration;
  uint256 targetCommitteeSize;
  uint256 lagInEpochs;
  uint256 aztecProofSubmissionEpochs;
  uint256 slashingQuorum;
  uint256 slashingRoundSize;
  uint256 slashingLifetimeInRounds;
  uint256 slashingExecutionDelayInRounds;
  uint256[3] slashAmounts;
  uint256 slashingOffsetInRounds;
  SlasherFlavor slasherFlavor;
  address slashingVetoer;
  uint256 slashingDisableDuration;
  uint256 manaTarget;
  uint256 exitDelaySeconds;
  uint32 version;
  EthValue provingCostPerMana;
  RewardConfig rewardConfig;
  RewardBoostConfig rewardBoostConfig;
  StakingQueueConfig stakingQueueConfig;
  uint256 localEjectionThreshold;
  Timestamp earliestRewardsClaimableTimestamp;
}

struct RollupConfig {
  bytes32 vkTreeRoot;
  bytes32 protocolContractTreeRoot;
  uint32 version;
  IERC20 feeAsset;
  IFeeJuicePortal feeAssetPortal;
  IVerifier epochProofVerifier;
  IInbox inbox;
  IOutbox outbox;
}

struct RollupStore {
  CompressedChainTips tips; // put first such that the struct slot structure is easy to follow for cheatcodes
  mapping(uint256 blockNumber => bytes32 archive) archives;
  // The following represents a circular buffer. Key is `blockNumber % size`.
  mapping(uint256 circularIndex => CompressedTempBlockLog temp) tempBlockLogs;
  RollupConfig config;
}

interface IRollupCore {
  event L2BlockProposed(uint256 indexed blockNumber, bytes32 indexed archive, bytes32[] versionedBlobHashes);
  event L2ProofVerified(uint256 indexed blockNumber, address indexed proverId);
  event BlockInvalidated(uint256 indexed blockNumber);
  event RewardConfigUpdated(RewardConfig rewardConfig);
  event ManaTargetUpdated(uint256 indexed manaTarget);
  event PrunedPending(uint256 provenBlockNumber, uint256 pendingBlockNumber);
  event RewardsClaimableUpdated(bool isRewardsClaimable);

  function setRewardsClaimable(bool _isRewardsClaimable) external;
  function claimSequencerRewards(address _recipient) external returns (uint256);
  function claimProverRewards(address _recipient, Epoch[] memory _epochs) external returns (uint256);

  function prune() external;
  function updateL1GasFeeOracle() external;

  function setProvingCostPerMana(EthValue _provingCostPerMana) external;

  function propose(
    ProposeArgs calldata _args,
    CommitteeAttestations memory _attestations,
    address[] memory _signers,
    Signature memory _attestationsAndSignersSignature,
    bytes calldata _blobInput
  ) external;

  function submitEpochRootProof(SubmitEpochRootProofArgs calldata _args) external;

  function invalidateBadAttestation(
    uint256 _blockNumber,
    CommitteeAttestations memory _attestations,
    address[] memory _committee,
    uint256 _invalidIndex
  ) external;

  function invalidateInsufficientAttestations(
    uint256 _blockNumber,
    CommitteeAttestations memory _attestations,
    address[] memory _committee
  ) external;

  function setRewardConfig(RewardConfig memory _config) external;
  function updateManaTarget(uint256 _manaTarget) external;

  // solhint-disable-next-line func-name-mixedcase
  function L1_BLOCK_AT_GENESIS() external view returns (uint256);
}

interface IRollup is IRollupCore, IHaveVersion {
  function validateHeaderWithAttestations(
    ProposedHeader calldata _header,
    CommitteeAttestations memory _attestations,
    address[] memory _signers,
    Signature memory _attestationsAndSignersSignature,
    bytes32 _digest,
    bytes32 _blobsHash,
    BlockHeaderValidationFlags memory _flags
  ) external;

  function canProposeAtTime(Timestamp _ts, bytes32 _archive, address _who) external returns (Slot, uint256);

  function getTips() external view returns (ChainTips memory);

  function status(uint256 _myHeaderBlockNumber)
    external
    view
    returns (
      uint256 provenBlockNumber,
      bytes32 provenArchive,
      uint256 pendingBlockNumber,
      bytes32 pendingArchive,
      bytes32 archiveOfMyBlock,
      Epoch provenEpochNumber
    );

  function getEpochProofPublicInputs(
    uint256 _start,
    uint256 _end,
    PublicInputArgs calldata _args,
    bytes32[] calldata _fees,
    bytes calldata _blobPublicInputs
  ) external view returns (bytes32[] memory);

  function validateBlobs(bytes calldata _blobsInputs) external view returns (bytes32[] memory, bytes32, bytes[] memory);

  function getManaBaseFeeComponentsAt(Timestamp _timestamp, bool _inFeeAsset)
    external
    view
    returns (ManaBaseFeeComponents memory);
  function getManaBaseFeeAt(Timestamp _timestamp, bool _inFeeAsset) external view returns (uint256);
  function getL1FeesAt(Timestamp _timestamp) external view returns (L1FeeData memory);
  function getFeeAssetPerEth() external view returns (FeeAssetPerEthE9);

  function getEpochForBlock(uint256 _blockNumber) external view returns (Epoch);
  function canPruneAtTime(Timestamp _ts) external view returns (bool);

  function archive() external view returns (bytes32);
  function archiveAt(uint256 _blockNumber) external view returns (bytes32);
  function getProvenBlockNumber() external view returns (uint256);
  function getPendingBlockNumber() external view returns (uint256);
  function getBlock(uint256 _blockNumber) external view returns (BlockLog memory);
  function getFeeHeader(uint256 _blockNumber) external view returns (FeeHeader memory);
  function getBlobCommitmentsHash(uint256 _blockNumber) external view returns (bytes32);
  function getCurrentBlobCommitmentsHash() external view returns (bytes32);

  function getSharesFor(address _prover) external view returns (uint256);
  function getSequencerRewards(address _sequencer) external view returns (uint256);
  function getCollectiveProverRewardsForEpoch(Epoch _epoch) external view returns (uint256);
  function getSpecificProverRewardsForEpoch(Epoch _epoch, address _prover) external view returns (uint256);
  function getHasSubmitted(Epoch _epoch, uint256 _length, address _prover) external view returns (bool);
  function getHasClaimed(address _prover, Epoch _epoch) external view returns (bool);

  function getProofSubmissionEpochs() external view returns (uint256);
  function getManaTarget() external view returns (uint256);
  function getManaLimit() external view returns (uint256);
  function getProvingCostPerManaInEth() external view returns (EthValue);

  function getProvingCostPerManaInFeeAsset() external view returns (FeeAssetValue);

  function getFeeAsset() external view returns (IERC20);
  function getFeeAssetPortal() external view returns (IFeeJuicePortal);
  function getRewardDistributor() external view returns (IRewardDistributor);
  function getBurnAddress() external view returns (address);

  function getInbox() external view returns (IInbox);
  function getOutbox() external view returns (IOutbox);

  function getRewardConfig() external view returns (RewardConfig memory);
  function getBlockReward() external view returns (uint256);
  function getEarliestRewardsClaimableTimestamp() external view returns (Timestamp);
  function isRewardsClaimable() external view returns (bool);
}


// File: lib/l1-contracts/src/core/interfaces/IStaking.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {StakingQueueConfig} from "@aztec/core/libraries/compressed-data/StakingQueueConfig.sol";
import {Exit, Status, AttesterView} from "@aztec/core/libraries/rollup/StakingLib.sol";
import {DepositArgs} from "@aztec/core/libraries/StakingQueue.sol";
import {AttesterConfig, GSE} from "@aztec/governance/GSE.sol";
import {G1Point, G2Point} from "@aztec/shared/libraries/BN254Lib.sol";
import {Timestamp, Epoch} from "@aztec/shared/libraries/TimeMath.sol";
import {IERC20} from "@oz/token/ERC20/IERC20.sol";

interface IStakingCore {
  event SlasherUpdated(address indexed oldSlasher, address indexed newSlasher);
  event LocalEjectionThresholdUpdated(
    uint256 indexed oldLocalEjectionThreshold, uint256 indexed newLocalEjectionThreshold
  );
  event ValidatorQueued(address indexed attester, address indexed withdrawer);
  event Deposit(
    address indexed attester,
    address indexed withdrawer,
    G1Point publicKeyInG1,
    G2Point publicKeyInG2,
    G1Point proofOfPossession,
    uint256 amount
  );
  event FailedDeposit(
    address indexed attester,
    address indexed withdrawer,
    G1Point publicKeyInG1,
    G2Point publicKeyInG2,
    G1Point proofOfPossession
  );
  event WithdrawInitiated(address indexed attester, address indexed recipient, uint256 amount);
  event WithdrawFinalized(address indexed attester, address indexed recipient, uint256 amount);
  event Slashed(address indexed attester, uint256 amount);
  event StakingQueueConfigUpdated(StakingQueueConfig config);

  function setSlasher(address _slasher) external;
  function setLocalEjectionThreshold(uint256 _localEjectionThreshold) external;
  function deposit(
    address _attester,
    address _withdrawer,
    G1Point memory _publicKeyInG1,
    G2Point memory _publicKeyInG2,
    G1Point memory _proofOfPossession,
    bool _moveWithLatestRollup
  ) external;
  function flushEntryQueue() external;
  function flushEntryQueue(uint256 _toAdd) external;
  function initiateWithdraw(address _attester, address _recipient) external returns (bool);
  function finalizeWithdraw(address _attester) external;
  function slash(address _attester, uint256 _amount) external returns (bool);
  function vote(uint256 _proposalId) external;
  function updateStakingQueueConfig(StakingQueueConfig memory _config) external;

  function getEntryQueueFlushSize() external view returns (uint256);
  function getActiveAttesterCount() external view returns (uint256);
}

interface IStaking is IStakingCore {
  function getConfig(address _attester) external view returns (AttesterConfig memory);
  function getExit(address _attester) external view returns (Exit memory);
  function getAttesterAtIndex(uint256 _index) external view returns (address);
  function getSlasher() external view returns (address);
  function getLocalEjectionThreshold() external view returns (uint256);
  function getStakingAsset() external view returns (IERC20);
  function getActivationThreshold() external view returns (uint256);
  function getEjectionThreshold() external view returns (uint256);
  function getExitDelay() external view returns (Timestamp);
  function getGSE() external view returns (GSE);
  function getAttesterView(address _attester) external view returns (AttesterView memory);
  function getStatus(address _attester) external view returns (Status);
  function getNextFlushableEpoch() external view returns (Epoch);
  function getEntryQueueLength() external view returns (uint256);
  function getEntryQueueAt(uint256 _index) external view returns (DepositArgs memory);
  function getAvailableValidatorFlushes() external view returns (uint256);
  function getIsBootstrapped() external view returns (bool);
}


// File: lib/l1-contracts/src/core/interfaces/IValidatorSelection.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {IEmperor} from "@aztec/governance/interfaces/IEmpire.sol";
import {Timestamp, Slot, Epoch} from "@aztec/shared/libraries/TimeMath.sol";
import {Checkpoints} from "@oz/utils/structs/Checkpoints.sol";

struct ValidatorSelectionStorage {
  // A mapping to snapshots of the validator set
  mapping(Epoch => bytes32 committeeCommitment) committeeCommitments;
  // Checkpointed map of epoch -> randao value
  Checkpoints.Trace224 randaos;
  uint32 targetCommitteeSize;
  uint32 lagInEpochs;
}

interface IValidatorSelectionCore {
  function setupEpoch() external;
  function checkpointRandao() external;
}

interface IValidatorSelection is IValidatorSelectionCore, IEmperor {
  function getProposerAt(Timestamp _ts) external returns (address);

  // Non view as uses transient storage
  function getCurrentEpochCommittee() external returns (address[] memory);
  function getCommitteeAt(Timestamp _ts) external returns (address[] memory);
  function getCommitteeCommitmentAt(Timestamp _ts) external returns (bytes32, uint256);
  function getEpochCommittee(Epoch _epoch) external returns (address[] memory);
  function getEpochCommitteeCommitment(Epoch _epoch) external returns (bytes32, uint256);

  // Stable
  function getCurrentEpoch() external view returns (Epoch);

  // Consider removing below this point
  function getTimestampForSlot(Slot _slotNumber) external view returns (Timestamp);

  function getSampleSeedAt(Timestamp _ts) external view returns (uint256);
  function getSamplingSizeAt(Timestamp _ts) external view returns (uint256);
  function getLagInEpochs() external view returns (uint256);
  function getCurrentSampleSeed() external view returns (uint256);

  function getEpochAt(Timestamp _ts) external view returns (Epoch);
  function getSlotAt(Timestamp _ts) external view returns (Slot);
  function getEpochAtSlot(Slot _slotNumber) external view returns (Epoch);

  function getGenesisTime() external view returns (Timestamp);
  function getSlotDuration() external view returns (uint256);
  function getEpochDuration() external view returns (uint256);
  function getTargetCommitteeSize() external view returns (uint256);
}


// File: lib/l1-contracts/src/core/interfaces/IVerifier.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

interface IVerifier {
  function verify(bytes calldata _proof, bytes32[] calldata _publicInputs) external view returns (bool);
}


// File: lib/l1-contracts/src/core/libraries/compressed-data/BlockLog.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {CompressedFeeHeader, FeeHeader, FeeHeaderLib} from "@aztec/core/libraries/compressed-data/fees/FeeStructs.sol";
import {CompressedSlot, CompressedTimeMath} from "@aztec/shared/libraries/CompressedTimeMath.sol";
import {Slot} from "@aztec/shared/libraries/TimeMath.sol";

/**
 * @notice Struct for storing block data, set in proposal.
 * @param archive - Archive tree root of the block
 * @param headerHash - Hash of the proposed block header
 * @param blobCommitmentsHash - H(...H(H(commitment_0), commitment_1).... commitment_n) - used to validate we are using
 * the same blob commitments on L1 and in the rollup circuit
 * @param attestationsHash - Hash of the attestations for this block
 * @param payloadDigest - Digest of the proposal payload that was attested to
 * @param slotNumber - This block's slot
 */
struct BlockLog {
  bytes32 archive;
  bytes32 headerHash;
  bytes32 blobCommitmentsHash;
  bytes32 attestationsHash;
  bytes32 payloadDigest;
  Slot slotNumber;
  FeeHeader feeHeader;
}

struct TempBlockLog {
  bytes32 headerHash;
  bytes32 blobCommitmentsHash;
  bytes32 attestationsHash;
  bytes32 payloadDigest;
  Slot slotNumber;
  FeeHeader feeHeader;
}

struct CompressedTempBlockLog {
  bytes32 headerHash;
  bytes32 blobCommitmentsHash;
  bytes32 attestationsHash;
  bytes32 payloadDigest;
  CompressedSlot slotNumber;
  CompressedFeeHeader feeHeader;
}

library CompressedTempBlockLogLib {
  using CompressedTimeMath for Slot;
  using CompressedTimeMath for CompressedSlot;
  using FeeHeaderLib for FeeHeader;
  using FeeHeaderLib for CompressedFeeHeader;

  function compress(TempBlockLog memory _blockLog) internal pure returns (CompressedTempBlockLog memory) {
    return CompressedTempBlockLog({
      headerHash: _blockLog.headerHash,
      blobCommitmentsHash: _blockLog.blobCommitmentsHash,
      attestationsHash: _blockLog.attestationsHash,
      payloadDigest: _blockLog.payloadDigest,
      slotNumber: _blockLog.slotNumber.compress(),
      feeHeader: _blockLog.feeHeader.compress()
    });
  }

  function decompress(CompressedTempBlockLog memory _compressedBlockLog) internal pure returns (TempBlockLog memory) {
    return TempBlockLog({
      headerHash: _compressedBlockLog.headerHash,
      blobCommitmentsHash: _compressedBlockLog.blobCommitmentsHash,
      attestationsHash: _compressedBlockLog.attestationsHash,
      payloadDigest: _compressedBlockLog.payloadDigest,
      slotNumber: _compressedBlockLog.slotNumber.decompress(),
      feeHeader: _compressedBlockLog.feeHeader.decompress()
    });
  }
}


// File: lib/l1-contracts/src/core/libraries/rollup/FeeLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {BlobLib} from "@aztec-blob-lib/BlobLib.sol";
import {
  EthValue,
  FeeAssetValue,
  FeeAssetPerEthE9,
  CompressedFeeConfig,
  FeeConfigLib,
  FeeConfig,
  PriceLib
} from "@aztec/core/libraries/compressed-data/fees/FeeConfig.sol";
import {
  L1FeeData,
  CompressedL1FeeData,
  L1GasOracleValues,
  FeeStructsLib,
  FeeHeader,
  CompressedFeeHeader,
  FeeHeaderLib
} from "@aztec/core/libraries/compressed-data/fees/FeeStructs.sol";
import {CompressedSlot, CompressedTimeMath} from "@aztec/shared/libraries/CompressedTimeMath.sol";
import {Math} from "@oz/utils/math/Math.sol";
import {SafeCast} from "@oz/utils/math/SafeCast.sol";
import {SignedMath} from "@oz/utils/math/SignedMath.sol";
import {Errors} from "./../Errors.sol";
import {Slot, Timestamp, TimeLib} from "./../TimeLib.sol";
import {STFLib} from "./STFLib.sol";

// The lowest number of fee asset per eth is 10 with a precision of 1e9.
uint256 constant MINIMUM_FEE_ASSET_PER_ETH = 10e9;
uint256 constant MAX_FEE_ASSET_PRICE_MODIFIER = 1e6;
uint256 constant FEE_ASSET_PRICE_UPDATE_FRACTION = 100e6;

uint256 constant L1_GAS_PER_BLOCK_PROPOSED = 300_000;
uint256 constant L1_GAS_PER_EPOCH_VERIFIED = 1_000_000;

uint256 constant MINIMUM_CONGESTION_MULTIPLIER = 1e9;

// The magic values are used to have the fakeExponential case where
// (numerator / denominator) is close to 0.117, as that leads to ~1.125 multiplier
// per increase by TARGET of the numerator;
uint256 constant MAGIC_CONGESTION_VALUE_DIVISOR = 1e8;
uint256 constant MAGIC_CONGESTION_VALUE_MULTIPLIER = 854_700_854;

uint256 constant BLOB_GAS_PER_BLOB = 2 ** 17;
uint256 constant BLOBS_PER_BLOCK = 3;

struct OracleInput {
  int256 feeAssetPriceModifier;
}

struct ManaBaseFeeComponents {
  uint256 congestionCost;
  uint256 congestionMultiplier;
  uint256 sequencerCost;
  uint256 proverCost;
}

struct FeeStore {
  CompressedFeeConfig config;
  L1GasOracleValues l1GasOracleValues;
  mapping(uint256 blockNumber => CompressedFeeHeader feeHeader) feeHeaders;
}

library FeeLib {
  using Math for uint256;
  using SafeCast for int256;
  using SafeCast for uint256;
  using SignedMath for int256;
  using PriceLib for EthValue;
  using TimeLib for Slot;
  using TimeLib for Timestamp;

  using FeeHeaderLib for FeeHeader;
  using FeeHeaderLib for CompressedFeeHeader;
  using CompressedTimeMath for CompressedSlot;
  using CompressedTimeMath for Slot;

  using FeeStructsLib for L1FeeData;
  using FeeStructsLib for CompressedL1FeeData;
  using FeeConfigLib for FeeConfig;
  using FeeConfigLib for CompressedFeeConfig;

  Slot internal constant LIFETIME = Slot.wrap(5);
  Slot internal constant LAG = Slot.wrap(2);

  bytes32 private constant FEE_STORE_POSITION = keccak256("aztec.fee.storage");

  function initialize(uint256 _manaTarget, EthValue _provingCostPerMana) internal {
    FeeStore storage feeStore = getStorage();

    feeStore.config = FeeConfig({
      manaTarget: _manaTarget,
      congestionUpdateFraction: _manaTarget * MAGIC_CONGESTION_VALUE_MULTIPLIER / MAGIC_CONGESTION_VALUE_DIVISOR,
      provingCostPerMana: _provingCostPerMana
    }).compress();

    feeStore.l1GasOracleValues = L1GasOracleValues({
      pre: L1FeeData({baseFee: 1 gwei, blobFee: 1}).compress(),
      post: L1FeeData({baseFee: block.basefee, blobFee: BlobLib.getBlobBaseFee()}).compress(),
      slotOfChange: LIFETIME.compress()
    });
  }

  function updateManaTarget(uint256 _manaTarget) internal {
    FeeStore storage feeStore = getStorage();

    FeeConfig memory config = feeStore.config.decompress();
    config.manaTarget = _manaTarget;
    config.congestionUpdateFraction = _manaTarget * MAGIC_CONGESTION_VALUE_MULTIPLIER / MAGIC_CONGESTION_VALUE_DIVISOR;

    feeStore.config = config.compress();
  }

  function updateProvingCostPerMana(EthValue _provingCostPerMana) internal {
    FeeStore storage feeStore = getStorage();
    FeeConfig memory config = feeStore.config.decompress();
    config.provingCostPerMana = _provingCostPerMana;
    feeStore.config = config.compress();
  }

  function updateL1GasFeeOracle() internal {
    Slot slot = Timestamp.wrap(block.timestamp).slotFromTimestamp();
    // The slot where we find a new queued value acceptable
    FeeStore storage feeStore = getStorage();

    Slot acceptableSlot = feeStore.l1GasOracleValues.slotOfChange.decompress() + (LIFETIME - LAG);

    if (slot < acceptableSlot) {
      return;
    }

    feeStore.l1GasOracleValues = L1GasOracleValues({
      pre: feeStore.l1GasOracleValues.post,
      post: L1FeeData({baseFee: block.basefee, blobFee: BlobLib.getBlobBaseFee()}).compress(),
      slotOfChange: (slot + LAG).compress()
    });
  }

  function computeFeeHeader(
    uint256 _blockNumber,
    int256 _feeAssetPriceModifier,
    uint256 _manaUsed,
    uint256 _congestionCost,
    uint256 _proverCost
  ) internal view returns (FeeHeader memory) {
    require(
      SignedMath.abs(_feeAssetPriceModifier) <= MAX_FEE_ASSET_PRICE_MODIFIER,
      Errors.FeeLib__InvalidFeeAssetPriceModifier()
    );
    CompressedFeeHeader parentFeeHeader = STFLib.getFeeHeader(_blockNumber - 1);
    return FeeHeader({
      excessMana: FeeLib.computeExcessMana(parentFeeHeader),
      feeAssetPriceNumerator: FeeLib.clampedAdd(parentFeeHeader.getFeeAssetPriceNumerator(), _feeAssetPriceModifier),
      manaUsed: _manaUsed,
      congestionCost: _congestionCost,
      proverCost: _proverCost
    });
  }

  function getL1FeesAt(Timestamp _timestamp) internal view returns (L1FeeData memory) {
    FeeStore storage feeStore = getStorage();
    return _timestamp.slotFromTimestamp() < feeStore.l1GasOracleValues.slotOfChange.decompress()
      ? feeStore.l1GasOracleValues.pre.decompress()
      : feeStore.l1GasOracleValues.post.decompress();
  }

  function getManaBaseFeeComponentsAt(uint256 _blockOfInterest, Timestamp _timestamp, bool _inFeeAsset)
    internal
    view
    returns (ManaBaseFeeComponents memory)
  {
    FeeStore storage feeStore = getStorage();

    uint256 manaTarget = feeStore.config.getManaTarget();

    if (manaTarget == 0) {
      return ManaBaseFeeComponents({sequencerCost: 0, proverCost: 0, congestionCost: 0, congestionMultiplier: 0});
    }

    EthValue sequencerCostPerMana;
    EthValue proverCostPerMana;
    EthValue total;

    {
      L1FeeData memory fees = FeeLib.getL1FeesAt(_timestamp);

      // Sequencer cost per mana
      {
        uint256 ethUsed =
          (L1_GAS_PER_BLOCK_PROPOSED * fees.baseFee) + (BLOBS_PER_BLOCK * BLOB_GAS_PER_BLOB * fees.blobFee);

        sequencerCostPerMana = EthValue.wrap(Math.mulDiv(ethUsed, 1, manaTarget, Math.Rounding.Ceil));
      }

      // Prover cost per mana
      {
        proverCostPerMana = EthValue.wrap(
          Math.mulDiv(
            Math.mulDiv(L1_GAS_PER_EPOCH_VERIFIED, fees.baseFee, TimeLib.getStorage().epochDuration, Math.Rounding.Ceil),
            1,
            manaTarget,
            Math.Rounding.Ceil
          )
        ) + feeStore.config.getProvingCostPerMana();
      }

      total = sequencerCostPerMana + proverCostPerMana;
    }

    CompressedFeeHeader parentFeeHeader = STFLib.getFeeHeader(_blockOfInterest);
    uint256 excessMana =
      FeeLib.clampedAdd(parentFeeHeader.getExcessMana() + parentFeeHeader.getManaUsed(), -int256(manaTarget));
    uint256 congestionMultiplier_ = congestionMultiplier(excessMana);

    EthValue congestionCost = EthValue.wrap(
      Math.mulDiv(EthValue.unwrap(total), congestionMultiplier_, MINIMUM_CONGESTION_MULTIPLIER, Math.Rounding.Floor)
    ) - total;

    FeeAssetPerEthE9 feeAssetPrice =
      _inFeeAsset ? FeeLib.getFeeAssetPerEthAtBlock(_blockOfInterest) : FeeAssetPerEthE9.wrap(1e9);

    return ManaBaseFeeComponents({
      sequencerCost: FeeAssetValue.unwrap(sequencerCostPerMana.toFeeAsset(feeAssetPrice)),
      proverCost: FeeAssetValue.unwrap(proverCostPerMana.toFeeAsset(feeAssetPrice)),
      congestionCost: FeeAssetValue.unwrap(congestionCost.toFeeAsset(feeAssetPrice)),
      congestionMultiplier: congestionMultiplier_
    });
  }

  function isTxsEnabled() internal view returns (bool) {
    // If the target is 0, the limit is 0. And no transactions can enter
    return getManaTarget() > 0;
  }

  function getManaTarget() internal view returns (uint256) {
    return getStorage().config.getManaTarget();
  }

  function getManaLimit() internal view returns (uint256) {
    FeeStore storage feeStore = getStorage();
    return feeStore.config.getManaTarget() * 2;
  }

  function getProvingCostPerMana() internal view returns (EthValue) {
    return getStorage().config.getProvingCostPerMana();
  }

  function getFeeAssetPerEthAtBlock(uint256 _blockNumber) internal view returns (FeeAssetPerEthE9) {
    return getFeeAssetPerEth(STFLib.getFeeHeader(_blockNumber).getFeeAssetPriceNumerator());
  }

  function computeExcessMana(CompressedFeeHeader _feeHeader) internal view returns (uint256) {
    FeeStore storage feeStore = getStorage();
    return clampedAdd(_feeHeader.getExcessMana() + _feeHeader.getManaUsed(), -int256(feeStore.config.getManaTarget()));
  }

  function congestionMultiplier(uint256 _numerator) internal view returns (uint256) {
    FeeStore storage feeStore = getStorage();
    return fakeExponential(MINIMUM_CONGESTION_MULTIPLIER, _numerator, feeStore.config.getCongestionUpdateFraction());
  }

  function getFeeAssetPerEth(uint256 _numerator) internal pure returns (FeeAssetPerEthE9) {
    return
      FeeAssetPerEthE9.wrap(fakeExponential(MINIMUM_FEE_ASSET_PER_ETH, _numerator, FEE_ASSET_PRICE_UPDATE_FRACTION));
  }

  function summedBaseFee(ManaBaseFeeComponents memory _components) internal pure returns (uint256) {
    return _components.sequencerCost + _components.proverCost + _components.congestionCost;
  }

  function getStorage() internal pure returns (FeeStore storage storageStruct) {
    bytes32 position = FEE_STORE_POSITION;
    assembly {
      storageStruct.slot := position
    }
  }

  /**
   * @notice  Clamps the addition of a signed integer to a uint256
   *          Useful for running values, whose minimum value will be 0
   *          but should not throw if going below.
   * @param _a The base value
   * @param _b The value to add
   * @return The clamped value
   */
  function clampedAdd(uint256 _a, int256 _b) internal pure returns (uint256) {
    if (_b >= 0) {
      return _a + _b.toUint256();
    }

    uint256 sub = SignedMath.abs(_b);

    if (_a > sub) {
      return _a - sub;
    }

    return 0;
  }

  /**
   * @notice An approximation of the exponential function: factor * e ** (numerator / denominator)
   *
   *         The function is the same as used in EIP-4844
   *         https://github.com/ethereum/EIPs/blob/master/EIPS/eip-4844.md
   *
   *         Approximated using a taylor series.
   *         For shorthand below, let `a = factor`, `x = numerator`, `d = denominator`
   *
   *         f(x) =  a
   *              + (a * x) / d
   *              + (a * x ** 2) / (2 * d ** 2)
   *              + (a * x ** 3) / (6 * d ** 3)
   *              + (a * x ** 4) / (24 * d ** 4)
   *              + (a * x ** 5) / (120 * d ** 5)
   *              + ...
   *
   *         For integer precision purposes, we will multiply by the denominator for intermediary steps and then
   *         finally do a division by it.
   *         The notation below might look slightly strange, but it is to try to convey the program flow below.
   *
   *         e(x) = (          a * d
   *                 +         a * d * x / d
   *                 +       ((a * d * x / d) * x) / (2 * d)
   *                 +     ((((a * d * x / d) * x) / (2 * d)) * x) / (3 * d)
   *                 +   ((((((a * d * x / d) * x) / (2 * d)) * x) / (3 * d)) * x) / (4 * d)
   *                 + ((((((((a * d * x / d) * x) / (2 * d)) * x) / (3 * d)) * x) / (4 * d)) * x) / (5 * d)
   *                 + ...
   *                 ) / d
   *
   *         The notation might make it a bit of a pain to look at, but f(x) and e(x) are the same.
   *         Gotta love integer math.
   *
   * @dev   Notice that as _numerator grows, the computation will quickly overflow.
   *        As long as the `_denominator` is fairly small, it won't bring us back down to not overflow
   *        For our purposes, this is acceptable, as if we have a fee that is so high that it would overflow and throw
   *        then we would have other problems.
   *
   * @param _factor The base value
   * @param _numerator The numerator
   * @param _denominator The denominator
   * @return The approximated value `_factor * e ** (_numerator / _denominator)`
   */
  function fakeExponential(uint256 _factor, uint256 _numerator, uint256 _denominator) private pure returns (uint256) {
    uint256 i = 1;
    uint256 output = 0;
    uint256 numeratorAccumulator = _factor * _denominator;
    while (numeratorAccumulator > 0) {
      output += numeratorAccumulator;
      numeratorAccumulator = (numeratorAccumulator * _numerator) / (_denominator * i);
      i += 1;
    }
    return output / _denominator;
  }
}


// File: lib/l1-contracts/src/core/libraries/rollup/ProposedHeaderLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {Hash} from "@aztec/core/libraries/crypto/Hash.sol";

import {Slot, Timestamp} from "@aztec/core/libraries/TimeLib.sol";
import {SafeCast} from "@oz/utils/math/SafeCast.sol";

struct AppendOnlyTreeSnapshot {
  bytes32 root;
  uint32 nextAvailableLeafIndex;
}

struct PartialStateReference {
  AppendOnlyTreeSnapshot noteHashTree;
  AppendOnlyTreeSnapshot nullifierTree;
  AppendOnlyTreeSnapshot publicDataTree;
}

struct StateReference {
  AppendOnlyTreeSnapshot l1ToL2MessageTree;
  // Note: Can't use "partial" name here as in protocol specs because it is a reserved solidity keyword
  PartialStateReference partialStateReference;
}

struct GasFees {
  uint128 feePerDaGas;
  uint128 feePerL2Gas;
}

struct ContentCommitment {
  bytes32 blobsHash;
  bytes32 inHash;
  bytes32 outHash;
}

struct ProposedHeader {
  bytes32 lastArchiveRoot;
  ContentCommitment contentCommitment;
  Slot slotNumber;
  Timestamp timestamp;
  address coinbase;
  bytes32 feeRecipient;
  GasFees gasFees;
  uint256 totalManaUsed;
}

/**
 * @title ProposedHeader Library
 * @author Aztec Labs
 * @notice Decoding and validating a proposed L2 block header
 */
library ProposedHeaderLib {
  using SafeCast for uint256;

  /**
   * @notice  Hash the proposed header
   *
   * @dev     The hashing here MUST match what is in the proposed_block_header.ts
   *
   * @param _header The header to hash
   *
   * @return The hash of the header
   */
  function hash(ProposedHeader memory _header) internal pure returns (bytes32) {
    return Hash.sha256ToField(
      abi.encodePacked(
        _header.lastArchiveRoot,
        _header.contentCommitment.blobsHash,
        _header.contentCommitment.inHash,
        _header.contentCommitment.outHash,
        _header.slotNumber,
        Timestamp.unwrap(_header.timestamp).toUint64(),
        _header.coinbase,
        _header.feeRecipient,
        _header.gasFees.feePerDaGas,
        _header.gasFees.feePerL2Gas,
        _header.totalManaUsed
      )
    );
  }
}


// File: lib/l1-contracts/src/core/libraries/rollup/StakingLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {IStakingCore} from "@aztec/core/interfaces/IStaking.sol";
import {
  StakingQueueConfig,
  CompressedStakingQueueConfig,
  StakingQueueConfigLib
} from "@aztec/core/libraries/compressed-data/StakingQueueConfig.sol";
import {Errors} from "@aztec/core/libraries/Errors.sol";
import {StakingQueueLib, StakingQueue, DepositArgs} from "@aztec/core/libraries/StakingQueue.sol";
import {TimeLib, Timestamp, Epoch} from "@aztec/core/libraries/TimeLib.sol";
import {Governance} from "@aztec/governance/Governance.sol";
import {GSE, AttesterConfig, IGSECore} from "@aztec/governance/GSE.sol";
import {Proposal} from "@aztec/governance/interfaces/IGovernance.sol";
import {ProposalLib} from "@aztec/governance/libraries/ProposalLib.sol";
import {GovernanceProposer} from "@aztec/governance/proposer/GovernanceProposer.sol";
import {G1Point, G2Point} from "@aztec/shared/libraries/BN254Lib.sol";
import {
  CompressedTimeMath, CompressedTimestamp, CompressedEpoch
} from "@aztec/shared/libraries/CompressedTimeMath.sol";
import {IERC20} from "@oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "@oz/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@oz/utils/math/Math.sol";
import {SafeCast} from "@oz/utils/math/SafeCast.sol";

// None -> Does not exist in our setup
// Validating -> Participating as validator
// Zombie -> Not participating as validator, but have funds in setup,
// 			 hit if slashes and going below the minimum
// Exiting -> In the process of exiting the system
enum Status {
  NONE,
  VALIDATING,
  ZOMBIE,
  EXITING
}

/**
 * @notice Represents a validator's exit from the staking system
 * @dev Used to track withdrawal details and timing for validators leaving the system.
 *      The exit can be created in two scenarios:
 *      1. Voluntary withdrawal: Validator calls initiateWithdraw() -> recipientOrWithdrawer is the final recipient
 *      2. Slashing-induced exit: Validator gets slashed -> recipientOrWithdrawer is the withdrawer who must later
 *         call initiateWithdraw() to specify a recipient
 *
 *      The recipientOrWithdrawer field serves dual purposes:
 *      - When isRecipient=true: This address will receive the withdrawn funds
 *      - When isRecipient=false: This address (the withdrawer) can call initiateWithdraw() to set a recipient
 *
 *      Workflow for slashing-induced exits:
 *      1. Slashing occurs -> Exit created with recipientOrWithdrawer=withdrawer, isRecipient=false
 *      2. Withdrawer calls initiateWithdraw() -> Updates to recipientOrWithdrawer=recipient, isRecipient=true
 *      3. After delay period -> finalizeWithdraw() can transfer funds to the recipient
 * @param withdrawalId Unique identifier for this withdrawal from the GSE contract
 * @param amount The amount of stake being withdrawn
 * @param exitableAt Timestamp when the stake becomes withdrawable after delay period
 * @param recipientOrWithdrawer Address that can either receive funds (if isRecipient) or initiate withdrawal (if
 * !isRecipient)
 * @param isRecipient True if recipientOrWithdrawer is the recipient, false if it's the withdrawer
 * @param exists True if this exit record exists, false if not yet created
 */
struct Exit {
  uint256 withdrawalId;
  uint256 amount;
  Timestamp exitableAt;
  address recipientOrWithdrawer;
  bool isRecipient;
  bool exists;
}

struct AttesterView {
  Status status;
  uint256 effectiveBalance;
  Exit exit;
  AttesterConfig config;
}

struct StakingStorage {
  IERC20 stakingAsset;
  address slasher;
  uint96 localEjectionThreshold;
  GSE gse;
  CompressedTimestamp exitDelay;
  mapping(address attester => Exit) exits;
  CompressedStakingQueueConfig queueConfig;
  StakingQueue entryQueue;
  CompressedEpoch nextFlushableEpoch;
  uint32 availableValidatorFlushes;
  bool isBootstrapped;
}

library StakingLib {
  using SafeCast for uint256;
  using SafeERC20 for IERC20;
  using StakingQueueLib for StakingQueue;
  using ProposalLib for Proposal;
  using StakingQueueConfigLib for CompressedStakingQueueConfig;
  using StakingQueueConfigLib for StakingQueueConfig;
  using CompressedTimeMath for CompressedTimestamp;
  using CompressedTimeMath for Timestamp;
  using CompressedTimeMath for CompressedEpoch;
  using CompressedTimeMath for Epoch;

  bytes32 private constant STAKING_SLOT = keccak256("aztec.core.staking.storage");

  function initialize(
    IERC20 _stakingAsset,
    GSE _gse,
    Timestamp _exitDelay,
    address _slasher,
    StakingQueueConfig memory _config,
    uint256 _localEjectionThreshold
  ) internal {
    StakingStorage storage store = getStorage();
    store.stakingAsset = _stakingAsset;
    store.gse = _gse;
    store.exitDelay = _exitDelay.compress();
    store.slasher = _slasher;
    store.queueConfig = _config.compress();
    store.entryQueue.init();
    store.localEjectionThreshold = _localEjectionThreshold.toUint96();
  }

  function setSlasher(address _slasher) internal {
    StakingStorage storage store = getStorage();

    address oldSlasher = store.slasher;
    store.slasher = _slasher;

    emit IStakingCore.SlasherUpdated(oldSlasher, _slasher);
  }

  function setLocalEjectionThreshold(uint256 _localEjectionThreshold) internal {
    StakingStorage storage store = getStorage();

    uint256 oldLocalEjectionThreshold = store.localEjectionThreshold;
    store.localEjectionThreshold = _localEjectionThreshold.toUint96();

    emit IStakingCore.LocalEjectionThresholdUpdated(oldLocalEjectionThreshold, _localEjectionThreshold);
  }

  /**
   * @notice Vote on a governance proposal with the rollup's voting power
   * @dev Only votes if:
   *      1. This rollup is the current canonical instance according to governance proposer
   *      2. This rollup was canonical when the proposal was created
   *      3. The proposal was created by the governance proposer
   * @param _proposalId The ID of the proposal to vote on
   */
  function vote(uint256 _proposalId) internal {
    StakingStorage storage store = getStorage();
    Governance gov = store.gse.getGovernance();

    GovernanceProposer govProposer = GovernanceProposer(gov.governanceProposer());
    // We only vote if we are the canonical instance
    require(address(this) == govProposer.getInstance(), Errors.Staking__NotCanonical(address(this)));
    address proposalProposer = govProposer.getProposalProposer(_proposalId);
    // We only vote if we were canonical when the proposal was created
    require(
      address(this) == proposalProposer, Errors.Staking__NotOurProposal(_proposalId, address(this), proposalProposer)
    );
    // We only vote if the proposal was created by the governance proposer
    Proposal memory proposal = gov.getProposal(_proposalId);
    require(proposal.proposer == address(govProposer), Errors.Staking__IncorrectGovProposer(_proposalId));

    Timestamp ts = proposal.creation + proposal.config.votingDelay;

    // Cast votes with all our power
    uint256 vp = store.gse.getVotingPowerAt(address(this), ts);
    store.gse.vote(_proposalId, vp, true);

    // If we are the canonical at the time of the proposal we also cast those votes.
    if (store.gse.getLatestRollupAt(ts) == address(this)) {
      address bonusInstance = store.gse.getBonusInstanceAddress();
      vp = store.gse.getVotingPowerAt(bonusInstance, ts);
      store.gse.voteWithBonus(_proposalId, vp, true);
    }
  }

  /**
   * @notice Completes a validator's withdrawal after the exit delay period
   * @param _attester The address of the validator completing withdrawal
   * @dev Reverts if the attester has no valid exit request (Staking__NotExiting) or if the exit delay period has not
   * elapsed (Staking__WithdrawalNotUnlockedYet)
   */
  function finalizeWithdraw(address _attester) internal {
    StakingStorage storage store = getStorage();
    // We load it into memory to cache it, as we will delete it before we use it.
    Exit memory exit = store.exits[_attester];
    require(exit.exists, Errors.Staking__NotExiting(_attester));
    require(exit.isRecipient, Errors.Staking__InitiateWithdrawNeeded(_attester));
    require(
      exit.exitableAt <= Timestamp.wrap(block.timestamp),
      Errors.Staking__WithdrawalNotUnlockedYet(Timestamp.wrap(block.timestamp), exit.exitableAt)
    );

    delete store.exits[_attester];

    store.gse.finalizeWithdraw(exit.withdrawalId);
    store.stakingAsset.safeTransfer(exit.recipientOrWithdrawer, exit.amount);

    emit IStakingCore.WithdrawFinalized(_attester, exit.recipientOrWithdrawer, exit.amount);
  }

  function trySlash(address _attester, uint256 _amount) internal returns (bool) {
    if (!isSlashable(_attester)) {
      return false;
    }
    slash(_attester, _amount);
    return true;
  }

  /**
   * @notice Slashes a validator's stake as punishment for misbehavior
   * @dev Only callable by the authorized slasher contract. Handles slashing for both exiting and active validators.
   *      For exiting validators, reduces their exit amount. For active validators, the balance will be reduced and
   *      an exit will be created if the remaining stake falls below the ejection threshold.
   * @param _attester The address of the validator to slash
   * @param _amount The amount of stake to slash
   */
  function slash(address _attester, uint256 _amount) internal {
    StakingStorage storage store = getStorage();
    require(msg.sender == store.slasher, Errors.Staking__NotSlasher(store.slasher, msg.sender));

    Exit storage exit = store.exits[_attester];

    if (exit.exists) {
      require(exit.exitableAt > Timestamp.wrap(block.timestamp), Errors.Staking__CannotSlashExitedStake(_attester));

      // If the slash amount is greater than the exit amount, bound it to the exit amount
      uint256 slashAmount = Math.min(_amount, exit.amount);

      if (exit.amount == slashAmount) {
        // If we slash the entire thing, nuke it entirely
        delete store.exits[_attester];
      } else {
        exit.amount -= slashAmount;
      }

      emit IStakingCore.Slashed(_attester, slashAmount);
    } else {
      // Get the effective balance of the attester
      uint256 effectiveBalance = store.gse.effectiveBalanceOf(address(this), _attester);
      require(effectiveBalance > 0, Errors.Staking__NoOneToSlash(_attester));

      address withdrawer = store.gse.getWithdrawer(_attester);

      // If the slash amount is greater than the effective balance, bound it to the effective balance
      uint256 slashAmount = Math.min(_amount, effectiveBalance);
      // The `localEjectionThreshold` might be stricter (larger) than the global (gse ejection threshold)
      uint256 toWithdraw =
        effectiveBalance - slashAmount < store.localEjectionThreshold ? effectiveBalance : slashAmount;

      (uint256 amountWithdrawn, bool isRemoved, uint256 withdrawalId) = store.gse.withdraw(_attester, toWithdraw);

      // The slashed amount remains in the contract permanently, effectively burning those tokens.
      uint256 toUser = amountWithdrawn - slashAmount;
      if (isRemoved && toUser > 0) {
        // Only if we remove the attester AND there is something left will we create an exit
        store.exits[_attester] = Exit({
          withdrawalId: withdrawalId,
          amount: toUser,
          exitableAt: Timestamp.wrap(block.timestamp) + store.exitDelay.decompress(),
          recipientOrWithdrawer: withdrawer,
          isRecipient: false,
          exists: true
        });
      }

      emit IStakingCore.Slashed(_attester, slashAmount);
    }
  }

  /**
   * @notice Deposits stake to add a new validator to the entry queue
   * @dev Transfers stake from the caller and adds the validator to the entry queue.
   *      The validator must not already be exiting. The attester and withdrawer addresses
   *      must be non-zero. The stake amount is fixed at the activation threshold.
   *      The validator will be processed from the queue in a future flushEntryQueue call.
   *
   * @param _attester The address that will act as the validator (sign attestations)
   * @param _withdrawer The address that can withdraw the stake
   * @param _publicKeyInG1 The G1 point for the BLS public key (used for efficient signature verification in GSE)
   * @param _publicKeyInG2 The G2 point for the BLS public key (used for BLS aggregation and pairing operations in GSE)
   * @param _proofOfPossession The proof of possession to show that the keys in G1 and G2 share the same secret key
   * @param _moveWithLatestRollup Whether to automatically stake on a new rollup instance after an upgrade
   */
  function deposit(
    address _attester,
    address _withdrawer,
    G1Point memory _publicKeyInG1,
    G2Point memory _publicKeyInG2,
    G1Point memory _proofOfPossession,
    bool _moveWithLatestRollup
  ) internal {
    require(
      _attester != address(0) && _withdrawer != address(0), Errors.Staking__InvalidDeposit(_attester, _withdrawer)
    );
    StakingStorage storage store = getStorage();
    // We don't allow deposits, if we are currently exiting.
    require(!store.exits[_attester].exists, Errors.Staking__AlreadyExiting(_attester));
    uint256 amount = store.gse.ACTIVATION_THRESHOLD();

    store.stakingAsset.safeTransferFrom(msg.sender, address(this), amount);
    store.entryQueue.enqueue(
      _attester, _withdrawer, _publicKeyInG1, _publicKeyInG2, _proofOfPossession, _moveWithLatestRollup
    );
    emit IStakingCore.ValidatorQueued(_attester, _withdrawer);
  }

  function updateAndGetAvailableFlushes() internal returns (uint256) {
    (uint256 flushes, Epoch currentEpoch, bool shouldUpdateState) = _calculateAvailableFlushes();

    if (shouldUpdateState) {
      StakingStorage storage store = getStorage();
      store.nextFlushableEpoch = (currentEpoch + Epoch.wrap(1)).compress();
      store.availableValidatorFlushes = flushes.toUint32();
    }

    return flushes;
  }

  /**
   * @notice Processes the validator entry queue to add new validators to the active set
   * @dev Processes up to min(maxAddableValidators, _toAdd) entries from the queue,
   *      attempting to deposit each validator into the Governance Staking Escrow (GSE).
   *
   *      For each validator:
   *      - Dequeues their entry from the queue
   *      - Attempts to deposit them into the GSE contract
   *      - On success: emits Deposit event
   *      - On failure: refunds their stake and emits FailedDeposit event
   *
   *      The function will revert if:
   *      - A deposit fails due to out of gas (to prevent queue draining attacks)
   *
   *      The function approves the GSE contract to spend the total stake amount needed for all deposits,
   *      then revokes the approval after processing is complete.
   *      It also updates the available validator flushes
   *
   * @param _toAdd - The max number the caller will try to add
   */
  function flushEntryQueue(uint256 _toAdd) internal {
    uint256 maxAddableValidators = updateAndGetAvailableFlushes();

    if (maxAddableValidators == 0) {
      return;
    }

    StakingStorage storage store = getStorage();

    uint256 queueLength = store.entryQueue.length();
    uint256 numToDequeue = Math.min(Math.min(maxAddableValidators, queueLength), _toAdd);

    if (numToDequeue == 0) {
      return;
    }

    // Approve the GSE to spend the total stake amount needed for all deposits.
    uint256 amount = store.gse.ACTIVATION_THRESHOLD();
    store.stakingAsset.approve(address(store.gse), amount * numToDequeue);
    uint256 depositCount = 0;
    for (uint256 i = 0; i < numToDequeue; i++) {
      DepositArgs memory args = store.entryQueue.dequeue();
      (bool success, bytes memory data) = address(store.gse).call(
        abi.encodeWithSelector(
          IGSECore.deposit.selector,
          args.attester,
          args.withdrawer,
          args.publicKeyInG1,
          args.publicKeyInG2,
          args.proofOfPossession,
          args.moveWithLatestRollup
        )
      );
      if (success) {
        depositCount++;
        emit IStakingCore.Deposit(
          args.attester, args.withdrawer, args.publicKeyInG1, args.publicKeyInG2, args.proofOfPossession, amount
        );
      } else {
        // If the deposit fails, we need to handle two cases:
        // 1. Normal failure (data.length > 0): We return the funds to the withdrawer and continue processing
        //    the queue. This prevents a single failed deposit from blocking the entire queue.
        // 2. Out of gas failure (data.length == 0): We revert the entire transaction. This prevents an attack
        //    where someone could drain the queue without making any deposits.
        //    We can safely assume data.length == 0 means out of gas since we only call trusted GSE contract.
        require(data.length > 0, Errors.Staking__DepositOutOfGas());
        store.stakingAsset.safeTransfer(args.withdrawer, amount);
        emit IStakingCore.FailedDeposit(
          args.attester, args.withdrawer, args.publicKeyInG1, args.publicKeyInG2, args.proofOfPossession
        );
      }
    }
    store.stakingAsset.approve(address(store.gse), 0);

    store.availableValidatorFlushes -= depositCount.toUint32();

    // If we have reached the bootstrap size, mark it as bootstrapped such that we don't re-enter it.
    if (
      !store.isBootstrapped
        && getAttesterCountAtTime(Timestamp.wrap(block.timestamp))
          >= store.queueConfig.decompress().bootstrapValidatorSetSize
    ) {
      store.isBootstrapped = true;
    }
  }

  /**
   * @notice Initiates withdrawal of a validator's stake
   * @dev Can be called by the registered withdrawer to start the exit process for a validator.
   *      Handles two cases:
   *      1. If an exit already exists (e.g. from slashing):
   *         - Only allows updating recipient if caller is withdrawer
   *         - Does not update the exit delay timer
   *      2. If no exit exists:
   *         - Requires validator has non-zero balance
   *         - Only allows registered withdrawer to initiate
   *         - Withdraws stake from GSE contract
   *         - Creates new exit with delay timer
   * @param _attester The validator address to withdraw stake for
   * @param _recipient The address that will receive the withdrawn stake
   * @return True if withdrawal was successfully initiated
   */
  function initiateWithdraw(address _attester, address _recipient) internal returns (bool) {
    require(_recipient != address(0), Errors.Staking__InvalidRecipient(_recipient));
    StakingStorage storage store = getStorage();

    if (store.exits[_attester].exists) {
      // If there is already an exit, we either started it and should revert
      // or it is because of a slash and we should update the recipient
      // Still only if we are the withdrawer
      // We DO NOT update the exitableAt
      require(!store.exits[_attester].isRecipient, Errors.Staking__NothingToExit(_attester));
      require(
        store.exits[_attester].recipientOrWithdrawer == msg.sender,
        Errors.Staking__NotWithdrawer(store.exits[_attester].recipientOrWithdrawer, msg.sender)
      );
      store.exits[_attester].recipientOrWithdrawer = _recipient;
      store.exits[_attester].isRecipient = true;

      emit IStakingCore.WithdrawInitiated(_attester, _recipient, store.exits[_attester].amount);
    } else {
      uint256 effectiveBalance = store.gse.effectiveBalanceOf(address(this), _attester);
      require(effectiveBalance > 0, Errors.Staking__NothingToExit(_attester));

      address withdrawer = store.gse.getWithdrawer(_attester);
      require(msg.sender == withdrawer, Errors.Staking__NotWithdrawer(withdrawer, msg.sender));

      (uint256 actualAmount, bool removed, uint256 withdrawalId) = store.gse.withdraw(_attester, effectiveBalance);
      require(removed, Errors.Staking__WithdrawFailed(_attester));

      store.exits[_attester] = Exit({
        withdrawalId: withdrawalId,
        amount: actualAmount,
        exitableAt: Timestamp.wrap(block.timestamp) + store.exitDelay.decompress(),
        recipientOrWithdrawer: _recipient,
        isRecipient: true,
        exists: true
      });
      emit IStakingCore.WithdrawInitiated(_attester, _recipient, actualAmount);
    }

    return true;
  }

  function updateStakingQueueConfig(StakingQueueConfig memory _config) internal {
    getStorage().queueConfig = _config.compress();
    emit IStakingCore.StakingQueueConfigUpdated(_config);
  }

  function getNextFlushableEpoch() internal view returns (Epoch) {
    return getStorage().nextFlushableEpoch.decompress();
  }

  function getEntryQueueLength() internal view returns (uint256) {
    return getStorage().entryQueue.length();
  }

  function isSlashable(address _attester) internal view returns (bool) {
    StakingStorage storage store = getStorage();
    Exit storage exit = store.exits[_attester];

    if (exit.exists) {
      return exit.exitableAt > Timestamp.wrap(block.timestamp);
    }

    uint256 effectiveBalance = store.gse.effectiveBalanceOf(address(this), _attester);
    return effectiveBalance > 0;
  }

  function getAttesterCountAtTime(Timestamp _timestamp) internal view returns (uint256) {
    return getStorage().gse.getAttesterCountAtTime(address(this), _timestamp);
  }

  function getAttesterAtIndex(uint256 _index) internal view returns (address) {
    return getStorage().gse.getAttesterFromIndexAtTime(address(this), _index, Timestamp.wrap(block.timestamp));
  }

  function getEntryQueueAt(uint256 _index) internal view returns (DepositArgs memory) {
    return getStorage().entryQueue.at(_index);
  }

  function getAttesterFromIndexAtTime(uint256 _index, Timestamp _timestamp) internal view returns (address) {
    return getStorage().gse.getAttesterFromIndexAtTime(address(this), _index, _timestamp);
  }

  function getAttestersFromIndicesAtTime(Timestamp _timestamp, uint256[] memory _indices)
    internal
    view
    returns (address[] memory)
  {
    return getStorage().gse.getAttestersFromIndicesAtTime(address(this), _timestamp, _indices);
  }

  function getExit(address _attester) internal view returns (Exit memory) {
    return getStorage().exits[_attester];
  }

  function getConfig(address _attester) internal view returns (AttesterConfig memory) {
    return getStorage().gse.getConfig(_attester);
  }

  function getAttesterView(address _attester) internal view returns (AttesterView memory) {
    return AttesterView({
      status: getStatus(_attester),
      effectiveBalance: getStorage().gse.effectiveBalanceOf(address(this), _attester),
      exit: getExit(_attester),
      config: getConfig(_attester)
    });
  }

  function getStatus(address _attester) internal view returns (Status) {
    Exit memory exit = getExit(_attester);
    uint256 effectiveBalance = getStorage().gse.effectiveBalanceOf(address(this), _attester);

    Status status;
    if (exit.exists) {
      status = exit.isRecipient ? Status.EXITING : Status.ZOMBIE;
    } else {
      status = effectiveBalance > 0 ? Status.VALIDATING : Status.NONE;
    }

    return status;
  }

  /**
   * @notice Determines the maximum number of validators that could be flushed from the entry queue if there were
   * an unlimited number of validators in the queue - this function provides a theoretical limit.
   * @dev Implements three-phase validator set management to control initial validator onboarding (called floodgates):
   *      1. Bootstrap phase: When no active validators exist, the queue must grow to the bootstrap validator set size
   *         constant from config before any validators can be flushed. This creates an initial "floodgate" that
   *         prevents small numbers of validators from activating before reaching the desired bootstrap size.
   *      2. Growth phase: Once the bootstrap size is reached, allows a large fixed batch size (bootstrapFlushSize) to
   *         be flushed at once. This enables the initial large cohort of validators to activate together.
   *      3. Normal phase: After the initial bootstrap and growth phases, returns a number proportional to the current
   *         set size for conservative steady-state growth, unless constrained by configuration (`normalFlushSizeMin`).
   *
   *      All phases are subject to a hard cap of `maxQueueFlushSize`.
   *
   *      The motivation for floodgates is that the whole system starts producing blocks with what is considered
   *      a sufficiently decentralized set of validators.
   *
   *      Note that Governance has the ability to close the validator set for this instance by setting
   *      `normalFlushSizeMin` to zero and `normalFlushSizeQuotient` to a very high value. If this is done, this
   *      function will always return zero and no new validator can enter.
   *
   * @param _activeAttesterCount - The number of active attesters
   * @return - The maximum number of validators that could be flushed from the entry queue.
   */
  function getEntryQueueFlushSize(uint256 _activeAttesterCount) internal view returns (uint256) {
    StakingStorage storage store = getStorage();
    StakingQueueConfig memory config = store.queueConfig.decompress();

    uint256 queueSize = store.entryQueue.length();

    // Only if there is bootstrap values configured will we look into bootstrap or growth phases.
    if (config.bootstrapValidatorSetSize > 0 && !store.isBootstrapped) {
      // If bootstrap:
      if (_activeAttesterCount == 0 && queueSize < config.bootstrapValidatorSetSize) {
        return 0;
      }

      // If growth:
      if (_activeAttesterCount < config.bootstrapValidatorSetSize) {
        return config.bootstrapFlushSize;
      }
    }

    // If normal:
    return Math.min(
      Math.max(_activeAttesterCount / config.normalFlushSizeQuotient, config.normalFlushSizeMin),
      config.maxQueueFlushSize
    );
  }

  function getAvailableValidatorFlushes() internal view returns (uint256) {
    (uint256 flushes,,) = _calculateAvailableFlushes();
    return flushes;
  }

  function getCachedAvailableValidatorFlushes() internal view returns (uint256) {
    return getStorage().availableValidatorFlushes;
  }

  function getStorage() internal pure returns (StakingStorage storage storageStruct) {
    bytes32 position = STAKING_SLOT;
    assembly {
      storageStruct.slot := position
    }
  }

  function _calculateAvailableFlushes()
    private
    view
    returns (uint256 flushes, Epoch currentEpoch, bool shouldUpdateState)
  {
    StakingStorage storage store = getStorage();
    currentEpoch = TimeLib.epochFromTimestamp(Timestamp.wrap(block.timestamp));

    if (store.nextFlushableEpoch.decompress() > currentEpoch) {
      return (store.availableValidatorFlushes, currentEpoch, false);
    }

    uint256 activeAttesterCount = getAttesterCountAtTime(Timestamp.wrap(block.timestamp));
    uint256 newFlushes = getEntryQueueFlushSize(activeAttesterCount);

    return (newFlushes, currentEpoch, true);
  }
}


// File: lib/l1-contracts/src/governance/GSE.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {Bn254LibWrapper} from "@aztec/governance/Bn254LibWrapper.sol";
import {Governance} from "@aztec/governance/Governance.sol";
import {Proposal} from "@aztec/governance/interfaces/IGovernance.sol";
import {IPayload} from "@aztec/governance/interfaces/IPayload.sol";
import {AddressSnapshotLib, SnapshottedAddressSet} from "@aztec/governance/libraries/AddressSnapshotLib.sol";
import {
  DepositDelegationLib, DepositAndDelegationAccounting
} from "@aztec/governance/libraries/DepositDelegationLib.sol";
import {Errors} from "@aztec/governance/libraries/Errors.sol";
import {G1Point, G2Point} from "@aztec/shared/libraries/BN254Lib.sol";
import {Timestamp} from "@aztec/shared/libraries/TimeMath.sol";
import {Ownable} from "@oz/access/Ownable.sol";
import {IERC20} from "@oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "@oz/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@oz/utils/math/SafeCast.sol";
import {Checkpoints} from "@oz/utils/structs/Checkpoints.sol";

// Struct to store configuration of an attester (block producer)
// Keep track of the actor who can initiate and control withdraws for the attester.
// Keep track of the public key in G1 of BN254 that has registered on the instance
struct AttesterConfig {
  G1Point publicKey;
  address withdrawer;
}

// Struct to track the attesters (block producers) on a particular rollup instance
// throughout time, along with each attester's current config.
// Finally a flag to track if the instance exists.
struct InstanceAttesterRegistry {
  SnapshottedAddressSet attesters;
  bool exists;
}

interface IGSECore {
  event Deposit(address indexed instance, address indexed attester, address withdrawer);

  function setGovernance(Governance _governance) external;
  function setProofOfPossessionGasLimit(uint64 _proofOfPossessionGasLimit) external;
  function addRollup(address _rollup) external;
  function deposit(
    address _attester,
    address _withdrawer,
    G1Point memory _publicKeyInG1,
    G2Point memory _publicKeyInG2,
    G1Point memory _proofOfPossession,
    bool _moveWithLatestRollup
  ) external;
  function withdraw(address _attester, uint256 _amount) external returns (uint256, bool, uint256);
  function delegate(address _instance, address _attester, address _delegatee) external;
  function vote(uint256 _proposalId, uint256 _amount, bool _support) external;
  function voteWithBonus(uint256 _proposalId, uint256 _amount, bool _support) external;
  function finalizeWithdraw(uint256 _withdrawalId) external;
  function proposeWithLock(IPayload _proposal, address _to) external returns (uint256);

  function isRegistered(address _instance, address _attester) external view returns (bool);
  function isRollupRegistered(address _instance) external view returns (bool);
  function getLatestRollup() external view returns (address);
  function getLatestRollupAt(Timestamp _timestamp) external view returns (address);
  function getGovernance() external view returns (Governance);
}

interface IGSE is IGSECore {
  function getRegistrationDigest(G1Point memory _publicKey) external view returns (G1Point memory);
  function getDelegatee(address _instance, address _attester) external view returns (address);
  function getVotingPower(address _attester) external view returns (uint256);
  function getVotingPowerAt(address _attester, Timestamp _timestamp) external view returns (uint256);

  function getWithdrawer(address _attester) external view returns (address);
  function balanceOf(address _instance, address _attester) external view returns (uint256);
  function effectiveBalanceOf(address _instance, address _attester) external view returns (uint256);
  function supplyOf(address _instance) external view returns (uint256);
  function totalSupply() external view returns (uint256);
  function getConfig(address _attester) external view returns (AttesterConfig memory);
  function getAttesterCountAtTime(address _instance, Timestamp _timestamp) external view returns (uint256);

  function getAttestersFromIndicesAtTime(address _instance, Timestamp _timestamp, uint256[] memory _indices)
    external
    view
    returns (address[] memory);
  function getG1PublicKeysFromAddresses(address[] memory _attesters) external view returns (G1Point[] memory);
  function getAttesterFromIndexAtTime(address _instance, uint256 _index, Timestamp _timestamp)
    external
    view
    returns (address);
  function getPowerUsed(address _delegatee, uint256 _proposalId) external view returns (uint256);
  function getBonusInstanceAddress() external view returns (address);
}

/**
 * @title GSECore
 * @author Aztec Labs
 * @notice The core Governance Staking Escrow contract that handles the deposits of attesters on rollup instances.
 *         It is responsible for:
 *         - depositing/withdrawing attesters on rollup instances
 *         - providing rollup instances with historical views of their attesters
 *         - allowing depositors to delegate their voting power
 *         - allowing delegatees to vote at governance
 *         - maintaining a set of "bonus" attesters which are always deposited on behalf of the latest rollup
 *
 * NB: The "bonus" attesters are thus automatically "moved along" whenever the latest rollup changes.
 * That is, at the point of the rollup getting added, the bonus is immediately available.
 * This allows the latest rollup to start with a set of attesters, rather than requiring them to exit
 * the old rollup and deposit in the new one.
 *
 * NB: The "latest" rollup in this contract does not technically need to be the "canonical" rollup
 * according to the Registry, but in practice, it will be unless the new rollup does not use the GSE.
 * Proposals which add rollups that DO want to use the GSE MUST call addRollup to both the Registry and the GSE.
 * See RegisterNewRollupVersionPayload.sol for an example.
 *
 * NB: The "owner" of the GSE is intended to be the Governance contract, but there is a circular
 * dependency in that we also want the GSE to be registered as the first beneficiary of the governance
 * contract so that we don't need to go through a governance proposal to add it. To that end,
 * this contract's view of `governance` needs to be set. So the current flow is to deploy the GSE with the owner
 * set to the deployer, then deploy Governance, passing the GSE as the initial/sole authorized beneficiary,
 * then have the deployer `setGovernance`, and then `transferOwnership` to Governance.
 */
contract GSECore is IGSECore, Ownable {
  using AddressSnapshotLib for SnapshottedAddressSet;
  using SafeCast for uint256;
  using SafeCast for uint224;
  using Checkpoints for Checkpoints.Trace224;
  using DepositDelegationLib for DepositAndDelegationAccounting;
  using SafeERC20 for IERC20;

  /**
   * Create a special "bonus" address for use by the latest rollup.
   * This is a convenience mechanism to allow attesters to always be staked on the latest rollup.
   *
   * As far as terminology, the GSE tracks deposits and voting/delegation data for "instances",
   * and an "instance" is either the address of a "true" rollup contract which was added via `addRollup`,
   * or (ONLY IN THIS CONTRACT) this special "bonus" address, which has its own accounting.
   *
   * NB: in every other context, "instance" refers broadly to a specific instance of an aztec rollup contract
   * (possibly inclusive of its family of related contracts e.g. Inbox, Outbox, etc.)
   *
   * Thus, this bonus address appears in `delegation` and `instances`, and from the perspective of the GSE,
   * it is an instance (though it can never be in the list of rollups).
   *
   * Lower in the code, we use "rollup" if we know we're talking about a rollup (often msg.sender),
   * and "instance" if we are talking about about either a rollup instance or the bonus instance.
   *
   * The latest rollup according to `rollups` may use the attesters and voting power
   * from the BONUS_INSTANCE_ADDRESS as a "bonus" to their own.
   *
   * One invariant of the GSE is that the attesters available to any rollup instance must form a set.
   * i.e. there must be no duplicates.
   *
   * Thus, for the latest rollup, there are two "buckets" of attesters available:
   * - the attesters that are associated with the rollup's address
   * - the attesters that are associated with the BONUS_INSTANCE_ADDRESS
   *
   * The GSE ensures that:
   * - each bucket individually is a set
   * - when you add these two buckets together, it is a set.
   *
   * For a rollup that is no longer the latest, the attesters available to it are the attesters that are
   * associated with the rollup's address. In effect, when a rollup goes from being the latest to not being
   * the latest, it loses all attesters that were associated with the bonus instance.
   *
   * In this way, the "effective" attesters/balance/etc for a rollup (at a point in time) is:
   * - the rollup's bucket and the bonus bucket if the rollup was the latest at that point in time
   * - only the rollup's bucket if the rollup was not the latest at that point in time
   *
   * Note further, that operations like deposit and withdraw are initiated by a rollup,
   * but the "affected instance" address will be either the rollup's address or the BONUS_INSTANCE_ADDRESS;
   * we will typically need to look at both instances to know what to do.
   *
   * NB: in a large way, the BONUS_INSTANCE_ADDRESS is the entire point of the GSE,
   * otherwise the rollups would've managed their own attesters/delegation/etc.
   */
  address public constant BONUS_INSTANCE_ADDRESS = address(uint160(uint256(keccak256("bonus-instance"))));

  // External wrapper of the BN254 library to more easily allow gas limits.
  Bn254LibWrapper internal immutable BN254_LIB_WRAPPER = new Bn254LibWrapper();

  // The amount of ASSET needed to add an attester to the set
  uint256 public immutable ACTIVATION_THRESHOLD;

  // The amount of ASSET needed to keep an attester in the set, if the attester balance fall below this threshold
  // the attester will be ejected from the set.
  uint256 public immutable EJECTION_THRESHOLD;

  // The asset used for sybil resistance and power in governance. Must match the ASSET in `Governance` to work as
  // intended.
  IERC20 public immutable ASSET;

  // The GSE's history of rollups.
  Checkpoints.Trace224 internal rollups;
  // Mapping from instance address to its historical attester information.
  mapping(address instanceAddress => InstanceAttesterRegistry instance) internal instances;

  // Global attester information
  mapping(address attester => AttesterConfig config) internal configOf;
  // Mapping from the hashed public key in G1 of BN254 to the keys are registered.
  mapping(bytes32 hashedPK1 => bool isRegistered) public ownedPKs;

  /**
   * Contains state for:
   * checkpointed total supply
   * instance => {
   *   checkpointed supply
   *   attester => { balance, delegatee }
   * }
   * delegatee => {
   *   checkpointed voting power
   *   proposal ID => { power used }
   * }
   */
  DepositAndDelegationAccounting internal delegation;
  Governance internal governance;

  // Gas limit for proof of possession validation.
  //
  // Must exceed the happy path gas consumption to ensure deposits succeed.
  // Acts as a cap on unhappy path gas usage to prevent excessive consumption.
  //
  // - Happy path average: 150K gas
  // - Buffer for loop: 50K gas
  // - Buffer for opcode cost changes: 50K gas
  //
  // WARNING: If set below happy path requirements, all deposits will fail.
  // Governance can adjust this value via proposal.
  uint64 public proofOfPossessionGasLimit = 250_000;

  /**
   * @dev enforces that the caller is a registered rollup.
   */
  modifier onlyRollup() {
    require(isRollupRegistered(msg.sender), Errors.GSE__NotRollup(msg.sender));
    _;
  }

  /**
   * @param __owner - The owner of the GSE.
   *                  Initially a deployer to allow adding an initial rollup, then handed over to governance.
   * @param _asset - The ERC20 token asset used in governance and for sybil resistance.
   *                 This token is deposited by attesters to gain voting power in governance
   *                 (ratio of voting power to staked amount is 1:1).
   * @param _activationThreshold - The amount of asset required to deposit an attester on the rollup.
   * @param _ejectionThreshold - The minimum amount of asset required to be in the set to be considered an attester.
   *                        If the balance falls below this threshold, the attester is ejected from the set.
   */
  constructor(address __owner, IERC20 _asset, uint256 _activationThreshold, uint256 _ejectionThreshold)
    Ownable(__owner)
  {
    ASSET = _asset;
    ACTIVATION_THRESHOLD = _activationThreshold;
    EJECTION_THRESHOLD = _ejectionThreshold;
    instances[BONUS_INSTANCE_ADDRESS].exists = true;
  }

  function setGovernance(Governance _governance) external override(IGSECore) onlyOwner {
    require(address(governance) == address(0), Errors.GSE__GovernanceAlreadySet());
    governance = _governance;
  }

  function setProofOfPossessionGasLimit(uint64 _proofOfPossessionGasLimit) external override(IGSECore) onlyOwner {
    proofOfPossessionGasLimit = _proofOfPossessionGasLimit;
  }

  /**
   * @notice  Adds another rollup to the instances, which is the new latest rollup.
   *          Only callable by the owner (usually governance) and only when the rollup is not already in the set
   *
   * @dev rollups only have access to the "bonus instance" while they are the most recent rollup.
   *
   * @dev The GSE only supports adding rollups, not removing them. If a rollup becomes compromised, governance can
   * simply add a new rollup and the bonus instance mechanism ensures a smooth transition by allowing the new rollup
   * to immediately inherit attesters.
   *
   * @dev Beware that multiple calls to `addRollup` at the same `block.timestamp` will override each other and only
   * the last will be in the `rollups`.
   *
   * @param _rollup - The address of the rollup to add
   */
  function addRollup(address _rollup) external override(IGSECore) onlyOwner {
    require(_rollup != address(0), Errors.GSE__InvalidRollupAddress(_rollup));
    require(!instances[_rollup].exists, Errors.GSE__RollupAlreadyRegistered(_rollup));
    instances[_rollup].exists = true;
    rollups.push(block.timestamp.toUint32(), uint224(uint160(_rollup)));
  }

  /**
   * @notice Deposits a new attester
   *
   * @dev msg.sender must be a registered rollup.
   *
   * @dev Transfers ASSET from msg.sender to the GSE, and then into Governance.
   *
   * @dev if _moveWithLatestRollup is true, then msg.sender must be the latest rollup.
   *
   * @dev An attester configuration is registered globally to avoid BLS troubles when moving stake.
   *
   * Suppose the registered rollups are A, then B, then C, so C's effective attesters are
   * those associated with C and the bonus address.
   *
   * Alice may come along now and deposit on A or B, with _moveWithLatestRollup=false in either case.
   *
   * For depositing into C, she can deposit *either* with _moveWithLatestRollup = true OR false.
   * If she deposits with _moveWithLatestRollup = false, then she is associated with C's address.
   * If she deposits with _moveWithLatestRollup = true, then she is associated with the bonus address.
   *
   * Suppose she deposits with _moveWithLatestRollup = true, and a new rollup D is added to the rollups.
   * Then her stake moves to D, and she is in the effective attesters of D.
   *
   * @param _attester     - The attester address on behalf of which the deposit is made.
   * @param _withdrawer   - Address which the user wish to use to initiate a withdraw for the `_attester` and
   *                        to update delegation with. The withdrawals are enforced by the rollup to which it is
   *                        controlled, so it is practically a value for the rollup to use, meaning dishonest rollup
   *                        can reject withdrawal attempts.
   * @param _publicKeyInG1 - BLS public key for the attester in G1
   * @param _publicKeyInG2 - BLS public key for the attester in G2
   * @param _proofOfPossession - A proof of possessions for the private key corresponding _publicKey in G1 and G2
   * @param _moveWithLatestRollup - Whether to deposit into the specific instance, or the bonus instance
   */
  function deposit(
    address _attester,
    address _withdrawer,
    G1Point memory _publicKeyInG1,
    G2Point memory _publicKeyInG2,
    G1Point memory _proofOfPossession,
    bool _moveWithLatestRollup
  ) external override(IGSECore) onlyRollup {
    bool isMsgSenderLatestRollup = getLatestRollup() == msg.sender;

    // If _moveWithLatestRollup is true, then msg.sender must be the latest rollup.
    if (_moveWithLatestRollup) {
      require(isMsgSenderLatestRollup, Errors.GSE__NotLatestRollup(msg.sender));
    }

    // Ensure that we are not already attesting on the rollup
    require(!isRegistered(msg.sender, _attester), Errors.GSE__AlreadyRegistered(msg.sender, _attester));

    // Ensure that if we are the latest rollup, we are not already attesting on the bonus instance.
    if (isMsgSenderLatestRollup) {
      require(
        !isRegistered(BONUS_INSTANCE_ADDRESS, _attester),
        Errors.GSE__AlreadyRegistered(BONUS_INSTANCE_ADDRESS, _attester)
      );
    }

    // Set the recipient instance address, i.e. the one that will receive the attester.
    // From above, we know that if we are here, and _moveWithLatestRollup is true,
    // then msg.sender is the latest instance,
    // but the user is targeting the bonus address.
    // Otherwise, we use the msg.sender, which we know is a registered rollup
    // thanks to the modifier.
    address recipientInstance = _moveWithLatestRollup ? BONUS_INSTANCE_ADDRESS : msg.sender;

    // Add the attester to the instance's checkpointed set of attesters.
    require(
      instances[recipientInstance].attesters.add(_attester), Errors.GSE__AlreadyRegistered(recipientInstance, _attester)
    );

    _checkProofOfPossession(_attester, _publicKeyInG1, _publicKeyInG2, _proofOfPossession);

    // This is the ONLY place where we set the configuration for an attester.
    // This means that their withdrawer and public keys are set once, globally.
    // If they exit, they must re-deposit with a new key.
    configOf[_attester] = AttesterConfig({withdrawer: _withdrawer, publicKey: _publicKeyInG1});

    delegation.delegate(recipientInstance, _attester, recipientInstance);
    delegation.increaseBalance(recipientInstance, _attester, ACTIVATION_THRESHOLD);

    ASSET.safeTransferFrom(msg.sender, address(this), ACTIVATION_THRESHOLD);

    Governance gov = getGovernance();
    ASSET.approve(address(gov), ACTIVATION_THRESHOLD);
    gov.deposit(address(this), ACTIVATION_THRESHOLD);

    emit Deposit(recipientInstance, _attester, _withdrawer);
  }

  /**
   * @notice  Withdraws at least the amount specified.
   *          If the leftover balance is less than the minimum deposit, the entire balance is withdrawn.
   *
   * @dev     To be used by a rollup to withdraw funds from the GSE. For example if slashing or
   *          just withdrawing events happen, a rollup can use this function to withdraw the funds.
   *          It looks in both the rollup instance and the bonus address for the attester.
   *
   * @dev     Note that all funds are returned to the rollup, so for slashing the rollup itself must
   *          address the problem of "what to do" with the funds. And it must look at the returned amount
   *          withdrawn and the bool.
   *
   * @param _attester - The attester to withdraw from.
   * @param _amount   - The amount of staking asset to withdraw. Has 1:1 ratio with voting power.
   *
   * @return The actual amount withdrawn.
   * @return True if attester is removed from set, false otherwise
   * @return The id of the withdrawal at the governance
   */
  function withdraw(address _attester, uint256 _amount)
    external
    override(IGSECore)
    onlyRollup
    returns (uint256, bool, uint256)
  {
    // We need to figure out where the attester is effectively located
    // we start by looking at the instance that is withdrawing the attester
    address withdrawingInstance = msg.sender;
    InstanceAttesterRegistry storage attesterRegistry = instances[msg.sender];
    bool foundAttester = attesterRegistry.attesters.contains(_attester);

    // If we haven't found the attester in the rollup instance, and we are latest rollup, go look in the "bonus"
    // instance.
    if (
      !foundAttester && getLatestRollup() == msg.sender
        && instances[BONUS_INSTANCE_ADDRESS].attesters.contains(_attester)
    ) {
      withdrawingInstance = BONUS_INSTANCE_ADDRESS;
      attesterRegistry = instances[BONUS_INSTANCE_ADDRESS];
      foundAttester = true;
    }

    require(foundAttester, Errors.GSE__NothingToExit(_attester));

    uint256 balance = delegation.getBalanceOf(withdrawingInstance, _attester);
    require(balance >= _amount, Errors.GSE__InsufficientBalance(balance, _amount));

    // First assume we are only withdrawing the amount specified.
    uint256 amountWithdrawn = _amount;
    // If the balance after withdrawal is less than the ejection threshold,
    // we will remove the attester from the instance.
    bool isRemoved = balance - _amount < EJECTION_THRESHOLD;

    // Note that the current implementation of the rollup does not allow for partial withdrawals,
    // via `initiateWithdraw`, so a "normal" withdrawal will always remove the attester from the instance.
    // However, if the attester is slashed, we might just reduce the balance.
    if (isRemoved) {
      require(attesterRegistry.attesters.remove(_attester), Errors.GSE__FailedToRemove(_attester));
      amountWithdrawn = balance;

      // When removing the user, remove the delegating as well.
      delegation.undelegate(withdrawingInstance, _attester);

      // NOTE
      // We intentionally did not remove the attester config.
      // Attester config is set ONCE when the attester is first seen by the GSE,
      // and is shared across all instances.
    }

    // Decrease the balance of the attester in the instance.
    // Move voting power from the attester's delegatee to address(0) (unless the delegatee is already address(0))
    // Reduce the supply of the instance and the total supply.
    delegation.decreaseBalance(withdrawingInstance, _attester, amountWithdrawn);

    // The withdrawal contains a pending amount that may be claimed using the withdrawal ID when a delay enforced by
    // the Governance contract has passed.
    // Note that the rollup is the one that receives the funds when the withdrawal is claimed.
    uint256 withdrawalId = getGovernance().initiateWithdraw(msg.sender, amountWithdrawn);

    return (amountWithdrawn, isRemoved, withdrawalId);
  }

  /**
   * @notice  A helper function to make it easy for users of the GSE to finalize
   *          a pending exit in the governance.
   *
   *          Kept in here since it is already connected to Governance:
   *          we don't want the rollup to have to deal with links to gov etc.
   *
   * @dev     Will be a no operation if the withdrawal is already collected.
   *
   * @param _withdrawalId - The id of the withdrawal
   */
  function finalizeWithdraw(uint256 _withdrawalId) external override(IGSECore) {
    Governance gov = getGovernance();
    if (!gov.getWithdrawal(_withdrawalId).claimed) {
      gov.finalizeWithdraw(_withdrawalId);
    }
  }

  /**
   * @notice Make a proposal to Governance via `Governance.proposeWithLock`
   *
   * @dev It is required to expose this on the GSE, since it is assumed that only the GSE can hold
   * power in Governance (see the comment at the top of Governance.sol).
   *
   * @dev Transfers governance's configured `lockAmount` of ASSET from msg.sender to the GSE,
   * and then into Governance.
   *
   * @dev Immediately creates a withdrawal from Governance for the `lockAmount`.
   *
   * @dev The delay until the withdrawal may be finalized is equal to the current `lockDelay` in Governance.
   *
   * @param _payload - The IPayload address, which is a contract that contains the proposed actions to be executed by
   * the governance.
   * @param _to - The address that will receive the withdrawn funds when the withdrawal is finalized (see
   * `finalizeWithdraw`)
   *
   * @return The id of the proposal
   */
  function proposeWithLock(IPayload _payload, address _to) external override(IGSECore) returns (uint256) {
    Governance gov = getGovernance();
    uint256 amount = gov.getConfiguration().proposeConfig.lockAmount;

    ASSET.safeTransferFrom(msg.sender, address(this), amount);
    ASSET.approve(address(gov), amount);

    gov.deposit(address(this), amount);

    return gov.proposeWithLock(_payload, _to);
  }

  /**
   * @notice  Delegates the voting power of `_attester` at `_instance` to `_delegatee`
   *
   *          Only callable by the `withdrawer` for the given `_attester` at the given
   *          `_instance`. This is to ensure that the depositor in poor mans delegation;
   *          listing another entity as the `attester`, still controls his voting power,
   *          even if someone else is running the node. Separately, it makes it simpler
   *          to use cold-storage for more impactful actions.
   *
   * @dev The delegatee may use this voting power to vote on proposals in Governance.
   *
   * Note that voting power for a delegatee is timestamped. The delegatee must have this
   * power before a proposal becomes "active" in order to use it.
   * See `Governance.getProposalState` for more details.
   *
   * @param _instance   - The address of the rollup instance (or bonus instance address)
   *                      to which the `_attester` deposit is pledged.
   * @param _attester   - The address of the attester to delegate on behalf of
   * @param _delegatee  - The delegatee that should receive the power
   */
  function delegate(address _instance, address _attester, address _delegatee) external override(IGSECore) {
    require(isRollupRegistered(_instance), Errors.GSE__InstanceDoesNotExist(_instance));
    address withdrawer = configOf[_attester].withdrawer;
    require(msg.sender == withdrawer, Errors.GSE__NotWithdrawer(withdrawer, msg.sender));
    delegation.delegate(_instance, _attester, _delegatee);
  }

  /**
   * @notice  Votes at the governance using the power delegated to `msg.sender`
   *
   * @param _proposalId - The id of the proposal in the governance to vote on
   * @param _amount     - The amount of voting power to use in the vote
   *                      In the gov, it is possible to do a vote with partial power
   * @param _support    - True if supporting the proposal, false otherwise.
   */
  function vote(uint256 _proposalId, uint256 _amount, bool _support) external override(IGSECore) {
    _vote(msg.sender, _proposalId, _amount, _support);
  }

  /**
   * @notice  Votes at the governance using the power delegated to the bonus instance.
   *          Only callable by the rollup that was the latest rollup at the time of the proposal.
   *
   * @param _proposalId - The id of the proposal in the governance to vote on
   * @param _amount     - The amount of voting power to use in the vote
   *                      In the gov, it is possible to do a vote with partial power
   */
  function voteWithBonus(uint256 _proposalId, uint256 _amount, bool _support) external override(IGSECore) {
    Timestamp ts = _pendingThrough(_proposalId);
    require(msg.sender == getLatestRollupAt(ts), Errors.GSE__NotLatestRollup(msg.sender));
    _vote(BONUS_INSTANCE_ADDRESS, _proposalId, _amount, _support);
  }

  function isRollupRegistered(address _instance) public view override(IGSECore) returns (bool) {
    return instances[_instance].exists;
  }

  /**
   * @notice  Lookup if the `_attester` is in the `_instance` attester set
   *
   * @param _instance   - The instance to look at
   * @param _attester   - The attester to lookup
   *
   * @return  True if the `_attester` is in the set of `_instance`, false otherwise
   */
  function isRegistered(address _instance, address _attester) public view override(IGSECore) returns (bool) {
    return instances[_instance].attesters.contains(_attester);
  }

  /**
   * @notice  Get the address of latest instance
   *
   * @return  The address of the latest instance
   */
  function getLatestRollup() public view override(IGSECore) returns (address) {
    return address(rollups.latest().toUint160());
  }

  /**
   * @notice  Get the address of the instance that was latest at time `_timestamp`
   *
   * @param _timestamp  - The timestamp to lookup
   *
   * @return  The address of the latest instance at the time of lookup
   */
  function getLatestRollupAt(Timestamp _timestamp) public view override(IGSECore) returns (address) {
    return address(rollups.upperLookup(Timestamp.unwrap(_timestamp).toUint32()).toUint160());
  }

  function getGovernance() public view override(IGSECore) returns (Governance) {
    return governance;
  }

  /**
   * @notice  Inner logic for the vote
   *
   * @dev     Fetches the timestamp where proposal becomes active, and use it for the voting power
   *          of the `_voter`
   *
   * @param _voter      - The voter
   * @param _proposalId - The proposal to vote on
   * @param _amount     - The amount of power to use
   * @param _support    - True to support the proposal, false otherwise
   */
  function _vote(address _voter, uint256 _proposalId, uint256 _amount, bool _support) internal {
    Timestamp ts = _pendingThrough(_proposalId);
    // Mark the power as spent within our delegation accounting.
    delegation.usePower(_voter, _proposalId, ts, _amount);
    // Vote on the proposal
    getGovernance().vote(_proposalId, _amount, _support);
  }

  function _checkProofOfPossession(
    address _attester,
    G1Point memory _publicKeyInG1,
    G2Point memory _publicKeyInG2,
    G1Point memory _proofOfPossession
  ) internal virtual {
    // Make sure the attester has not registered before
    G1Point memory previouslyRegisteredPoint = configOf[_attester].publicKey;
    require(
      (previouslyRegisteredPoint.x == 0 && previouslyRegisteredPoint.y == 0),
      Errors.GSE__CannotChangePublicKeys(previouslyRegisteredPoint.x, previouslyRegisteredPoint.y)
    );

    // Make sure the incoming point has not been seen before
    // NOTE: we only need to check for the existence of Pk1, and not also for Pk2,
    // as the Pk2 will be constrained to have the same underlying secret key as part of the proofOfPossession,
    // so existence/correctness of Pk2 is implied by existence/correctness of Pk1.
    bytes32 hashedIncomingPoint = keccak256(abi.encodePacked(_publicKeyInG1.x, _publicKeyInG1.y));
    require((!ownedPKs[hashedIncomingPoint]), Errors.GSE__ProofOfPossessionAlreadySeen(hashedIncomingPoint));
    ownedPKs[hashedIncomingPoint] = true;

    // We validate the proof of possession using an external contract to limit gas potentially "sacrificed"
    // in case of failure.
    require(
      BN254_LIB_WRAPPER.proofOfPossession{gas: proofOfPossessionGasLimit}(
        _publicKeyInG1, _publicKeyInG2, _proofOfPossession
      ),
      Errors.GSE__InvalidProofOfPossession()
    );
  }

  function _pendingThrough(uint256 _proposalId) internal view returns (Timestamp) {
    // Directly compute pendingThrough for memory proposal
    Proposal memory proposal = getGovernance().getProposal(_proposalId);
    return proposal.creation + proposal.config.votingDelay;
  }
}

contract GSE is IGSE, GSECore {
  using AddressSnapshotLib for SnapshottedAddressSet;
  using SafeCast for uint256;
  using SafeCast for uint224;
  using Checkpoints for Checkpoints.Trace224;
  using DepositDelegationLib for DepositAndDelegationAccounting;

  constructor(address __owner, IERC20 _asset, uint256 _activationThreshold, uint256 _ejectionThreshold)
    GSECore(__owner, _asset, _activationThreshold, _ejectionThreshold)
  {}

  /**
   * @notice  Get the registration digest of a public key
   *          by hashing the the public key to a point on the curve which may subsequently
   *          be signed by the corresponding private key.
   *
   * @param _publicKey - The public key to get the registration digest of
   *
   * @return The registration digest of the public key. Sign and submit as a proof of possession.
   */
  function getRegistrationDigest(G1Point memory _publicKey) external view override(IGSE) returns (G1Point memory) {
    return BN254_LIB_WRAPPER.g1ToDigestPoint(_publicKey);
  }

  function getConfig(address _attester) external view override(IGSE) returns (AttesterConfig memory) {
    return configOf[_attester];
  }

  function getWithdrawer(address _attester) external view override(IGSE) returns (address withdrawer) {
    AttesterConfig memory config = configOf[_attester];

    return config.withdrawer;
  }

  function balanceOf(address _instance, address _attester) external view override(IGSE) returns (uint256) {
    return delegation.getBalanceOf(_instance, _attester);
  }

  /**
   * @notice  Get the effective balance of the attester at the instance.
   *
   *          The effective balance is the balance of the attester at the specific instance or at the bonus if the
   *          instance is the latest rollup and he was not at the specific. We can do this as an `or` since the
   *          attester may only be active at one of them.
   *
   * @param _instance   - The instance to look at
   * @param _attester   - The attester to look at
   *
   * @return The effective balance of the attester at the instance
   */
  function effectiveBalanceOf(address _instance, address _attester) external view override(IGSE) returns (uint256) {
    uint256 balance = delegation.getBalanceOf(_instance, _attester);
    if (balance == 0 && getLatestRollup() == _instance) {
      return delegation.getBalanceOf(BONUS_INSTANCE_ADDRESS, _attester);
    }
    return balance;
  }

  function supplyOf(address _instance) external view override(IGSE) returns (uint256) {
    return delegation.getSupplyOf(_instance);
  }

  function totalSupply() external view override(IGSE) returns (uint256) {
    return delegation.getSupply();
  }

  function getDelegatee(address _instance, address _attester) external view override(IGSE) returns (address) {
    return delegation.getDelegatee(_instance, _attester);
  }

  function getVotingPower(address _delegatee) external view override(IGSE) returns (uint256) {
    return delegation.getVotingPower(_delegatee);
  }

  function getAttestersFromIndicesAtTime(address _instance, Timestamp _timestamp, uint256[] memory _indices)
    external
    view
    override(IGSE)
    returns (address[] memory)
  {
    return _getAddressFromIndicesAtTimestamp(_instance, _indices, _timestamp);
  }

  /**
   * @notice  Get the G1 public keys of the attesters
   *
   * NOTE: this function does NOT check if the attesters are CURRENTLY ACTIVE.
   *
   * @param _attesters  - The attesters to lookup
   *
   * @return The G1 public keys of the attesters
   */
  function getG1PublicKeysFromAddresses(address[] memory _attesters)
    external
    view
    override(IGSE)
    returns (G1Point[] memory)
  {
    G1Point[] memory keys = new G1Point[](_attesters.length);
    for (uint256 i = 0; i < _attesters.length; i++) {
      keys[i] = configOf[_attesters[i]].publicKey;
    }

    return keys;
  }

  function getAttesterFromIndexAtTime(address _instance, uint256 _index, Timestamp _timestamp)
    external
    view
    override(IGSE)
    returns (address)
  {
    uint256[] memory indices = new uint256[](1);
    indices[0] = _index;
    return _getAddressFromIndicesAtTimestamp(_instance, indices, _timestamp)[0];
  }

  function getPowerUsed(address _delegatee, uint256 _proposalId) external view override(IGSE) returns (uint256) {
    return delegation.getPowerUsed(_delegatee, _proposalId);
  }

  function getBonusInstanceAddress() external pure override(IGSE) returns (address) {
    return BONUS_INSTANCE_ADDRESS;
  }

  function getVotingPowerAt(address _delegatee, Timestamp _timestamp) public view override(IGSE) returns (uint256) {
    return delegation.getVotingPowerAt(_delegatee, _timestamp);
  }

  /**
   * @notice  Get the number of effective attesters at the instance at the time of `_timestamp`
   *          (including the bonus instance)
   *
   * @param _instance   - The instance to look at
   * @param _timestamp  - The timestamp to lookup
   *
   * @return The number of effective attesters at the instance at the time of `_timestamp`
   */
  function getAttesterCountAtTime(address _instance, Timestamp _timestamp) public view override(IGSE) returns (uint256) {
    InstanceAttesterRegistry storage store = instances[_instance];
    uint32 timestamp = Timestamp.unwrap(_timestamp).toUint32();

    uint256 count = store.attesters.lengthAtTimestamp(timestamp);
    if (getLatestRollupAt(_timestamp) == _instance) {
      count += instances[BONUS_INSTANCE_ADDRESS].attesters.lengthAtTimestamp(timestamp);
    }

    return count;
  }

  /**
   * @notice  Get the addresses of the attesters at the instance at the time of `_timestamp`
   *
   * @dev
   *
   * @param _instance   - The instance to look at
   * @param _indices    - The indices of the attesters to lookup
   * @param _timestamp  - The timestamp to lookup
   *
   * @return The addresses of the attesters at the instance at the time of `_timestamp`
   */
  function _getAddressFromIndicesAtTimestamp(address _instance, uint256[] memory _indices, Timestamp _timestamp)
    internal
    view
    returns (address[] memory)
  {
    address[] memory attesters = new address[](_indices.length);

    // Note: This function could get called where _instance is the bonus instance.
    // This is okay, because we know that in this case, `isLatestRollup` will be false.
    // So we won't double count.
    InstanceAttesterRegistry storage instanceStore = instances[_instance];
    InstanceAttesterRegistry storage bonusStore = instances[BONUS_INSTANCE_ADDRESS];
    bool isLatestRollup = getLatestRollupAt(_timestamp) == _instance;

    uint32 ts = Timestamp.unwrap(_timestamp).toUint32();

    // The effective size of the set will be the size of the instance attesters, plus the size of the bonus attesters
    // if the instance is the latest rollup. This will effectively work as one long list with [...instance, ...bonus]
    uint256 storeSize = instanceStore.attesters.lengthAtTimestamp(ts);
    uint256 canonicalSize = isLatestRollup ? bonusStore.attesters.lengthAtTimestamp(ts) : 0;
    uint256 totalSize = storeSize + canonicalSize;

    // We loop through the indices, and for each index we get the attester from the instance or bonus instance
    // depending on value in the collective list [...instance, ...bonus]
    for (uint256 i = 0; i < _indices.length; i++) {
      uint256 index = _indices[i];
      require(index < totalSize, Errors.GSE__OutOfBounds(index, totalSize));

      // since we have ensured that the index is not out of bounds, we can use the unsafe function in
      // `AddressSnapshotLib` to fetch if. We use the `recent` variant as we expect the attesters to
      // mainly be from recent history when fetched during tx execution.

      if (index < storeSize) {
        attesters[i] = instanceStore.attesters.unsafeGetRecentAddressFromIndexAtTimestamp(index, ts);
      } else if (isLatestRollup) {
        attesters[i] = bonusStore.attesters.unsafeGetRecentAddressFromIndexAtTimestamp(index - storeSize, ts);
      } else {
        revert Errors.GSE__FatalError("SHOULD NEVER HAPPEN");
      }
    }

    return attesters;
  }
}


// File: lib/l1-contracts/src/governance/interfaces/IRewardDistributor.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27;

interface IRewardDistributor {
  function claim(address _to, uint256 _amount) external;
  function recover(address _asset, address _to, uint256 _amount) external;
  function canonicalRollup() external view returns (address);
}


// File: lib/l1-contracts/src/shared/libraries/CompressedTimeMath.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {SafeCast} from "@oz/utils/math/SafeCast.sol";
import {Timestamp, Slot, Epoch} from "./TimeMath.sol";

type CompressedTimestamp is uint32;

type CompressedSlot is uint32;

type CompressedEpoch is uint32;

library CompressedTimeMath {
  function compress(Timestamp _timestamp) internal pure returns (CompressedTimestamp) {
    return CompressedTimestamp.wrap(SafeCast.toUint32(Timestamp.unwrap(_timestamp)));
  }

  function compress(Slot _slot) internal pure returns (CompressedSlot) {
    return CompressedSlot.wrap(SafeCast.toUint32(Slot.unwrap(_slot)));
  }

  function compress(Epoch _epoch) internal pure returns (CompressedEpoch) {
    return CompressedEpoch.wrap(SafeCast.toUint32(Epoch.unwrap(_epoch)));
  }

  function decompress(CompressedTimestamp _ts) internal pure returns (Timestamp) {
    return Timestamp.wrap(uint256(CompressedTimestamp.unwrap(_ts)));
  }

  function decompress(CompressedSlot _slot) internal pure returns (Slot) {
    return Slot.wrap(uint256(CompressedSlot.unwrap(_slot)));
  }

  function decompress(CompressedEpoch _epoch) internal pure returns (Epoch) {
    return Epoch.wrap(uint256(CompressedEpoch.unwrap(_epoch)));
  }
}


// File: lib/l1-contracts/src/shared/libraries/SignatureLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity ^0.8.27;

import {ECDSA} from "@oz/utils/cryptography/ECDSA.sol";

// Signature
struct Signature {
  uint8 v;
  bytes32 r;
  bytes32 s;
}

error SignatureLib__InvalidSignature(address, address);

library SignatureLib {
  /**
   * @notice Verifies a signature, throws if the signature is invalid or empty
   *
   * @param _signature - The signature to verify
   * @param _signer - The expected signer of the signature
   * @param _digest - The digest that was signed
   */
  function verify(Signature memory _signature, address _signer, bytes32 _digest) internal pure returns (bool) {
    address recovered = ECDSA.recover(_digest, _signature.v, _signature.r, _signature.s);
    require(_signer == recovered, SignatureLib__InvalidSignature(_signer, recovered));
    return true;
  }

  function isEmpty(Signature memory _signature) internal pure returns (bool) {
    return _signature.v == 0;
  }
}


// File: lib/l1-contracts/src/core/libraries/compressed-data/Tips.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {SafeCast} from "@oz/utils/math/SafeCast.sol";

struct ChainTips {
  uint256 pendingBlockNumber;
  uint256 provenBlockNumber;
}

type CompressedChainTips is uint256;

library ChainTipsLib {
  using SafeCast for uint256;

  uint256 internal constant PENDING_BLOCK_NUMBER_MASK =
    0xffffffffffffffffffffffffffffffff00000000000000000000000000000000;
  uint256 internal constant PROVEN_BLOCK_NUMBER_MASK = 0xffffffffffffffffffffffffffffffff;

  function getPendingBlockNumber(CompressedChainTips _compressedChainTips) internal pure returns (uint256) {
    return CompressedChainTips.unwrap(_compressedChainTips) >> 128;
  }

  function getProvenBlockNumber(CompressedChainTips _compressedChainTips) internal pure returns (uint256) {
    return CompressedChainTips.unwrap(_compressedChainTips) & PROVEN_BLOCK_NUMBER_MASK;
  }

  function updatePendingBlockNumber(CompressedChainTips _compressedChainTips, uint256 _pendingBlockNumber)
    internal
    pure
    returns (CompressedChainTips)
  {
    uint256 value = CompressedChainTips.unwrap(_compressedChainTips) & ~PENDING_BLOCK_NUMBER_MASK;
    return CompressedChainTips.wrap(value | (uint256(_pendingBlockNumber.toUint128()) << 128));
  }

  function updateProvenBlockNumber(CompressedChainTips _compressedChainTips, uint256 _provenBlockNumber)
    internal
    pure
    returns (CompressedChainTips)
  {
    uint256 value = CompressedChainTips.unwrap(_compressedChainTips) & ~PROVEN_BLOCK_NUMBER_MASK;
    return CompressedChainTips.wrap(value | _provenBlockNumber.toUint128());
  }

  function compress(ChainTips memory _chainTips) internal pure returns (CompressedChainTips) {
    // We are doing cast to uint128 but inside a uint256 to not wreck the shifting.
    uint256 pending = _chainTips.pendingBlockNumber.toUint128();
    uint256 proven = _chainTips.provenBlockNumber.toUint128();
    return CompressedChainTips.wrap((pending << 128) | proven);
  }

  function decompress(CompressedChainTips _compressedChainTips) internal pure returns (ChainTips memory) {
    return ChainTips({
      pendingBlockNumber: getPendingBlockNumber(_compressedChainTips),
      provenBlockNumber: getProvenBlockNumber(_compressedChainTips)
    });
  }
}


// File: lib/l1-contracts/src/core/libraries/rollup/ProposeLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {BlobLib} from "@aztec-blob-lib/BlobLib.sol";
import {RollupStore, IRollupCore, BlockHeaderValidationFlags} from "@aztec/core/interfaces/IRollup.sol";
import {TempBlockLog} from "@aztec/core/libraries/compressed-data/BlockLog.sol";
import {FeeHeader} from "@aztec/core/libraries/compressed-data/fees/FeeStructs.sol";
import {ChainTipsLib, CompressedChainTips} from "@aztec/core/libraries/compressed-data/Tips.sol";
import {Errors} from "@aztec/core/libraries/Errors.sol";
import {SignatureDomainSeparator, CommitteeAttestations} from "@aztec/core/libraries/rollup/AttestationLib.sol";
import {OracleInput, FeeLib, ManaBaseFeeComponents} from "@aztec/core/libraries/rollup/FeeLib.sol";
import {ValidatorSelectionLib} from "@aztec/core/libraries/rollup/ValidatorSelectionLib.sol";
import {Timestamp, Slot, Epoch, TimeLib} from "@aztec/core/libraries/TimeLib.sol";
import {CompressedSlot, CompressedTimeMath} from "@aztec/shared/libraries/CompressedTimeMath.sol";
import {Signature} from "@aztec/shared/libraries/SignatureLib.sol";
import {ProposedHeader, ProposedHeaderLib, StateReference} from "./ProposedHeaderLib.sol";
import {STFLib} from "./STFLib.sol";

struct ProposeArgs {
  bytes32 archive;
  // Including stateReference here so that the archiver can reconstruct the full block header.
  // It doesn't need to be in the proposed header as the values are not used in propose() and they are committed to
  // by the last archive and blobs hash.
  // It can be removed if the archiver can refer to world state for the updated roots.
  StateReference stateReference;
  OracleInput oracleInput;
  ProposedHeader header;
}

struct ProposePayload {
  bytes32 archive;
  StateReference stateReference;
  OracleInput oracleInput;
  bytes32 headerHash;
}

struct InterimProposeValues {
  ProposedHeader header;
  bytes32[] blobHashes;
  bytes32 blobsHashesCommitment;
  bytes[] blobCommitments;
  bytes32 inHash;
  bytes32 headerHash;
  bytes32 attestationsHash;
  bytes32 payloadDigest;
  Epoch currentEpoch;
  bool isFirstBlockOfEpoch;
  bool isTxsEnabled;
}

/**
 * @param header - The proposed block header
 * @param digest - The digest that signatures signed
 * @param currentTime - The time of execution
 * @param blobsHashesCommitment - The blobs hash for this block, provided for simpler future simulation
 * @param flags - Flags specific to the execution, whether certain checks should be skipped
 */
struct ValidateHeaderArgs {
  ProposedHeader header;
  bytes32 digest;
  uint256 manaBaseFee;
  bytes32 blobsHashesCommitment;
  BlockHeaderValidationFlags flags;
}

/**
 * @title ProposeLib
 * @author Aztec Labs
 * @notice Library responsible for handling the L2 block proposal flow in the Aztec rollup.
 *
 * @dev This library implements the core block proposal mechanism that allows designated proposers to submit
 *      new L2 blocks to extend the rollup chain. It orchestrates the entire proposal process including:
 *      - Blob validation and commitment calculation
 *      - Header validation against chain state and timing constraints
 *      - Validator selection and proposer verification
 *      - Fee calculation and mana consumption tracking
 *      - State transitions and archive updates
 *      - Message processing between L1 and L2 via the Inbox and Outbox contracts
 *
 *      The proposal flow operates within Aztec's time-based model where:
 *      - Each slot has a designated proposer selected from the validator set
 *      - Blocks must be proposed in the correct time slot and build on the current chain tip
 *      - Proposers must provide valid attestations from committee members
 *      - All state transitions are atomically applied upon successful validation
 *
 *      Key functions:
 *      - `propose`: Main entry point called from `RollupCore.propose`.
 *         Handles the complete block proposal process from validation to state updates.
 *      - `validateHeader`: Validates block header against chain state, timing, and fee requirements.
 *         Called internally from `propose`, and externally from `RollupCore.validateHeaderWithAttestations`,
 *         used by proposers to ensure the header is valid before submitting the tx.
 *
 *      Dependencies on other main libraries:
 *      - STFLib: State Transition Function library for chain state management, pruning, and storage access
 *      - FeeLib: Fee calculation library for mana pricing, L1 gas oracles, and fee header computation
 *      - ValidatorSelectionLib: Validator and committee management for epoch setup and proposer verification
 *      - BlobLib: Blob commitment validation and hash calculation for data availability
 *      - ProposedHeaderLib: Block header hashing and validation utilities
 *
 *      Security considerations:
 *      - Only the designated proposer for the current slot can propose a block, enforced by
 *        validating the proposer validator signature among attestations. All other attestations are not
 *        verified on chain until time of proof submission.
 *      - Each block must built on the immediate previous one, ensuring no forks. This is enforced by checking
 *        the last archive root and block numbers. If the previous block is invalid, the proposer is expected to
 *        first invalidate it.
 *      - Blob commitments are validated, to ensure that the values provided correctly match the actual blobs published
 */
library ProposeLib {
  using TimeLib for Timestamp;
  using TimeLib for Slot;
  using TimeLib for Epoch;
  using CompressedTimeMath for CompressedSlot;
  using ChainTipsLib for CompressedChainTips;

  /**
   * @notice  Publishes a new L2 block to the pending chain.
   * @dev     Handles a proposed L2 block, validates it, and updates rollup state adding it to the pending chain.
   *          Orchestrates blob validation, header validation, proposer verification, fee calculations, and state
   *          transitions. Automatically prunes unproven blocks if the proof submission window has passed.
   *
   *          Note that some validations and processes are disabled if the chain is configured to run without
   *          transactions, such as during ignition phase:
   *          - No fee header computation or L1 gas fee oracle update
   *          - No inbox message consumption or outbox message insertion
   *
   *          Validations performed:
   *          - Blob commitments against provided blob data: Errors.Rollup__InvalidBlobHash,
   *            Errors.Rollup__InvalidBlobProof
   *          - Block header validations (see validateHeader function for details)
   *          - Proposer signature is valid for designated slot proposer:
   *            Errors.ValidatorSelection__MissingProposerSignature
   *          - Inbox hash matches expected value (when txs enabled): Errors.Rollup__InvalidInHash
   *
   *          Validations NOT performed:
   *          - Committee attestations (only proposer signature verified)
   *          - Transaction validity and state root computation (done at proof submission via a validity proof)
   *
   *          State changes:
   *          - Increment pending block number
   *          - Store archive root for the new block number
   *          - Store block metadata in circular storage (TempBlockLog)
   *          - Update L1 gas fee oracle (when txs enabled)
   *          - Consume inbox messages (when txs enabled)
   *          - Insert outbox messages (when txs enabled)
   *          - Setup epoch for validator selection (first block of the epoch)
   *
   * @param _args - The arguments to propose the block
   * @param _attestations - Committee attestations in a packed format:
   *        - Contains an array of length equal to the committee size
   *        - At position `i`: if committee member `i` attested, contains their signature over the digest;
   *          if not, contains their address
   *        - Includes a bitmap indicating whether position `i` contains a signature (true) or address (false)
   *        - This format allows reconstructing the committee commitment (hash of all committee addresses)
   *          by either recovering addresses from signatures or using the addresses
   * @param _signers - Addresses of the signers in the attestations:
   *        - Must match the addresses that would be recovered from signatures in _attestations
   *        - Same length as the number of signatures in _attestations
   *        - Used to verify that the proposer is one of the committee members by allowing cheap reconstruction of the
   *          commitment
   *        - Allows computing committee commitment without expensive signature recovery on-chain thus saving gas
   *        - Nodes must validate actual signatures off-chain when downloading blocks
   * @param _blobsInput - The bytes to verify our input blob commitments match real blobs:
   *        - input[:1] - num blobs in block
   *        - input[1:] - blob commitments (48 bytes * num blobs in block)
   * @param _checkBlob - Whether to skip blob related checks. Hardcoded to true in RollupCore, exists only to be
   *          overridden in tests
   */
  function propose(
    ProposeArgs calldata _args,
    CommitteeAttestations memory _attestations,
    address[] memory _signers,
    Signature calldata _attestationsAndSignersSignature,
    bytes calldata _blobsInput,
    bool _checkBlob
  ) internal {
    // Prune unproven blocks if the proof submission window has passed
    if (STFLib.canPruneAtTime(Timestamp.wrap(block.timestamp))) {
      STFLib.prune();
    }

    // Keep intermediate values in memory to avoid stack too deep errors
    InterimProposeValues memory v;

    // Transactions are disabled during ignition phase
    v.isTxsEnabled = FeeLib.isTxsEnabled();

    // Since ignition have no transactions, we need not waste gas updating pricing oracle.
    if (v.isTxsEnabled) {
      FeeLib.updateL1GasFeeOracle();
    }

    // Validate blob commitments against actual blob data and extract hashes
    // TODO(#13430): The below blobsHashesCommitment known as blobsHash elsewhere in the code. The name is confusingly
    // similar to blobCommitmentsHash, see comment in BlobLib.sol -> validateBlobs().
    (v.blobHashes, v.blobsHashesCommitment, v.blobCommitments) = BlobLib.validateBlobs(_blobsInput, _checkBlob);

    v.header = _args.header;

    // Compute header hash for computing the payload digest
    v.headerHash = ProposedHeaderLib.hash(v.header);

    // Setup epoch by sampling the committee for the current epoch and setting the seed for the one after the next.
    // This is a no-op if the epoch is already set up, so it only gets executed by the first block of the epoch.
    v.currentEpoch = Timestamp.wrap(block.timestamp).epochFromTimestamp();
    ValidatorSelectionLib.setupEpoch(v.currentEpoch);

    // Calculate mana base fee components for header validation
    ManaBaseFeeComponents memory components;
    if (v.isTxsEnabled) {
      // Since ignition have no transactions, we need not waste gas computing the fee components
      components = getManaBaseFeeComponentsAt(Timestamp.wrap(block.timestamp), true);
    }

    // Create payload digest signed by the committee members
    v.payloadDigest = digest(
      ProposePayload({
        archive: _args.archive,
        stateReference: _args.stateReference,
        oracleInput: _args.oracleInput,
        headerHash: v.headerHash
      })
    );

    // Validate block header
    validateHeader(
      ValidateHeaderArgs({
        header: v.header,
        digest: v.payloadDigest,
        manaBaseFee: FeeLib.summedBaseFee(components),
        blobsHashesCommitment: v.blobsHashesCommitment,
        flags: BlockHeaderValidationFlags({ignoreDA: false})
      })
    );

    {
      // Verify that the proposer is the correct one for this slot by checking their signature in the attestations
      ValidatorSelectionLib.verifyProposer(
        v.header.slotNumber,
        v.currentEpoch,
        _attestations,
        _signers,
        v.payloadDigest,
        _attestationsAndSignersSignature,
        true
      );
    }

    // Begin state updates - get storage reference and current chain tips
    RollupStore storage rollupStore = STFLib.getStorage();
    CompressedChainTips tips = rollupStore.tips;

    // Increment block number and update chain tips
    uint256 blockNumber = tips.getPendingBlockNumber() + 1;
    tips = tips.updatePendingBlockNumber(blockNumber);

    // Calculate accumulated blob commitments hash for this block
    // Blob commitments are collected and proven per root rollup proof (per epoch),
    // so we need to know whether we are at the epoch start:
    v.isFirstBlockOfEpoch = v.currentEpoch > STFLib.getEpochForBlock(blockNumber - 1) || blockNumber == 1;
    bytes32 blobCommitmentsHash = BlobLib.calculateBlobCommitmentsHash(
      STFLib.getBlobCommitmentsHash(blockNumber - 1), v.blobCommitments, v.isFirstBlockOfEpoch
    );

    // Compute fee header for block metadata
    FeeHeader memory feeHeader;
    if (v.isTxsEnabled) {
      // Since ignition have no transactions, we need not waste gas deriving the fee header
      feeHeader = FeeLib.computeFeeHeader(
        blockNumber,
        _args.oracleInput.feeAssetPriceModifier,
        v.header.totalManaUsed,
        components.congestionCost,
        components.proverCost
      );
    }

    // Hash attestations for storage in block log
    // Compute attestationsHash from the attestations
    v.attestationsHash = keccak256(abi.encode(_attestations));

    // Commit state changes: update chain tips and store block data
    rollupStore.tips = tips;
    rollupStore.archives[blockNumber] = _args.archive;
    STFLib.addTempBlockLog(
      TempBlockLog({
        headerHash: v.headerHash,
        blobCommitmentsHash: blobCommitmentsHash,
        attestationsHash: v.attestationsHash,
        payloadDigest: v.payloadDigest,
        slotNumber: v.header.slotNumber,
        feeHeader: feeHeader
      })
    );

    // Handle L1<->L2 message processing (only when transactions are enabled)
    if (v.isTxsEnabled) {
      // Since ignition will have no transactions there will be no method to consume or output message.
      // Therefore we can ignore it as long as mana target is zero.
      // Since the inbox is async, it must enforce its own check to not try to insert if ignition.

      // Consume pending L1->L2 messages and validate against header commitment
      // @note  The block number here will always be >=1 as the genesis block is at 0
      v.inHash = rollupStore.config.inbox.consume(blockNumber);
      require(
        v.header.contentCommitment.inHash == v.inHash,
        Errors.Rollup__InvalidInHash(v.inHash, v.header.contentCommitment.inHash)
      );

      // Insert L2->L1 messages into outbox for later consumption
      rollupStore.config.outbox.insert(blockNumber, v.header.contentCommitment.outHash);
    }

    // Emit event for external listeners. Nodes rely on this event to update their state.
    emit IRollupCore.L2BlockProposed(blockNumber, _args.archive, v.blobHashes);
  }

  /**
   * @notice Validates a proposed block header against chain state and constraints
   * @dev Called internally from propose() and externally from RollupCore.validateHeaderWithAttestations()
   *      for proposers to check header validity before submitting transactions
   *
   *      Header validations performed:
   *      - Coinbase address is non-zero: Errors.Rollup__InvalidCoinbase
   *      - Mana usage within limits: Errors.Rollup__ManaLimitExceeded
   *      - Builds on correct parent block (archive root check): Errors.Rollup__InvalidArchive
   *      - Slot number greater than last block's slot: Errors.Rollup__SlotAlreadyInChain
   *      - Slot number matches current timestamp slot: Errors.HeaderLib__InvalidSlotNumber
   *      - Timestamp matches slot-derived timestamp: Errors.Rollup__InvalidTimestamp
   *      - Timestamp not in future: Errors.Rollup__TimestampInFuture
   *      - Blob hashes match commitment (unless DA checks ignored): Errors.Rollup__UnavailableTxs
   *      - DA fee is zero: Errors.Rollup__NonZeroDaFee
   *      - L2 gas fee matches computed mana base fee: Errors.Rollup__InvalidManaBaseFee
   *
   * @param _args Validation arguments including header, digest, mana base fee, and flags
   */
  function validateHeader(ValidateHeaderArgs memory _args) internal view {
    require(_args.header.coinbase != address(0), Errors.Rollup__InvalidCoinbase());
    require(_args.header.totalManaUsed <= FeeLib.getManaLimit(), Errors.Rollup__ManaLimitExceeded());

    Timestamp currentTime = Timestamp.wrap(block.timestamp);
    RollupStore storage rollupStore = STFLib.getStorage();

    uint256 pendingBlockNumber = STFLib.getEffectivePendingBlockNumber(currentTime);

    bytes32 tipArchive = rollupStore.archives[pendingBlockNumber];
    require(
      tipArchive == _args.header.lastArchiveRoot,
      Errors.Rollup__InvalidArchive(tipArchive, _args.header.lastArchiveRoot)
    );

    Slot slot = _args.header.slotNumber;
    Slot lastSlot = STFLib.getSlotNumber(pendingBlockNumber);
    require(slot > lastSlot, Errors.Rollup__SlotAlreadyInChain(lastSlot, slot));

    Slot currentSlot = currentTime.slotFromTimestamp();
    require(slot == currentSlot, Errors.HeaderLib__InvalidSlotNumber(currentSlot, slot));

    Timestamp timestamp = TimeLib.toTimestamp(slot);
    require(_args.header.timestamp == timestamp, Errors.Rollup__InvalidTimestamp(timestamp, _args.header.timestamp));

    require(timestamp <= currentTime, Errors.Rollup__TimestampInFuture(currentTime, timestamp));

    require(
      _args.flags.ignoreDA || _args.header.contentCommitment.blobsHash == _args.blobsHashesCommitment,
      Errors.Rollup__UnavailableTxs(_args.header.contentCommitment.blobsHash)
    );

    require(_args.header.gasFees.feePerDaGas == 0, Errors.Rollup__NonZeroDaFee());
    require(
      _args.header.gasFees.feePerL2Gas == _args.manaBaseFee,
      Errors.Rollup__InvalidManaBaseFee(_args.manaBaseFee, _args.header.gasFees.feePerL2Gas)
    );
  }

  /**
   * @notice  Gets the mana base fee components
   *          For more context, consult:
   *          https://github.com/AztecProtocol/engineering-designs/blob/main/in-progress/8757-fees/design.md
   *
   * @param _timestamp - The timestamp of the block
   * @param _inFeeAsset - Whether to return the fee in the fee asset or ETH
   *
   * @return The mana base fee components
   */
  function getManaBaseFeeComponentsAt(Timestamp _timestamp, bool _inFeeAsset)
    internal
    view
    returns (ManaBaseFeeComponents memory)
  {
    uint256 blockOfInterest = STFLib.getEffectivePendingBlockNumber(_timestamp);
    return FeeLib.getManaBaseFeeComponentsAt(blockOfInterest, _timestamp, _inFeeAsset);
  }

  function digest(ProposePayload memory _args) internal pure returns (bytes32) {
    return keccak256(abi.encode(SignatureDomainSeparator.blockAttestation, _args));
  }
}


// File: lib/l1-contracts/src/core/libraries/rollup/RewardLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {RollupStore, SubmitEpochRootProofArgs} from "@aztec/core/interfaces/IRollup.sol";
import {Errors} from "@aztec/core/libraries/Errors.sol";
import {CompressedFeeHeader, FeeHeaderLib, FeeLib} from "@aztec/core/libraries/rollup/FeeLib.sol";
import {STFLib} from "@aztec/core/libraries/rollup/STFLib.sol";
import {Epoch, Timestamp, TimeLib} from "@aztec/core/libraries/TimeLib.sol";
import {IBoosterCore} from "@aztec/core/reward-boost/RewardBooster.sol";
import {IRewardDistributor} from "@aztec/governance/interfaces/IRewardDistributor.sol";
import {CompressedTimeMath, CompressedTimestamp} from "@aztec/shared/libraries/CompressedTimeMath.sol";
import {IERC20} from "@oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "@oz/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@oz/utils/math/Math.sol";
import {SafeCast} from "@oz/utils/math/SafeCast.sol";
import {BitMaps} from "@oz/utils/structs/BitMaps.sol";

type Bps is uint32;

library BpsLib {
  function mul(uint256 _a, Bps _b) internal pure returns (uint256) {
    return _a * uint256(Bps.unwrap(_b)) / 10_000;
  }
}

struct SubEpochRewards {
  uint256 summedShares;
  mapping(address prover => uint256 shares) shares;
}

struct EpochRewards {
  uint128 longestProvenLength;
  uint128 rewards;
  mapping(uint256 length => SubEpochRewards) subEpoch;
}

struct RewardConfig {
  IRewardDistributor rewardDistributor;
  Bps sequencerBps;
  IBoosterCore booster;
  uint96 blockReward;
}

struct RewardStorage {
  mapping(address => uint256) sequencerRewards;
  mapping(Epoch => EpochRewards) epochRewards;
  mapping(address prover => BitMaps.BitMap claimed) proverClaimed;
  RewardConfig config;
  CompressedTimestamp earliestRewardsClaimableTimestamp;
  bool isRewardsClaimable;
}

struct Values {
  address sequencer;
  uint256 proverFee;
  uint256 sequencerFee;
  uint256 sequencerBlockReward;
  uint256 manaUsed;
}

struct Totals {
  uint256 feesToClaim;
  uint256 totalBurn;
}

library RewardLib {
  using SafeERC20 for IERC20;
  using BitMaps for BitMaps.BitMap;
  using CompressedTimeMath for CompressedTimestamp;
  using CompressedTimeMath for Timestamp;
  using TimeLib for Timestamp;
  using TimeLib for Epoch;
  using FeeHeaderLib for CompressedFeeHeader;
  using SafeCast for uint256;

  bytes32 private constant REWARD_STORAGE_POSITION = keccak256("aztec.reward.storage");

  // A Cuauhxicalli [kʷaːʍʃiˈkalːi] ("eagle gourd bowl") is a ceremonial Aztec vessel or altar used to hold offerings,
  // such as sacrificial hearts, during rituals performed within temples.
  address public constant BURN_ADDRESS = address(bytes20("CUAUHXICALLI"));

  function initialize(Timestamp _earliestRewardsClaimableTimestamp) internal {
    RewardStorage storage rewardStorage = getStorage();
    rewardStorage.earliestRewardsClaimableTimestamp = _earliestRewardsClaimableTimestamp.compress();
    rewardStorage.isRewardsClaimable = false;
  }

  function setConfig(RewardConfig memory _config) internal {
    require(Bps.unwrap(_config.sequencerBps) <= 10_000, Errors.RewardLib__InvalidSequencerBps());
    RewardStorage storage rewardStorage = getStorage();
    rewardStorage.config = _config;
  }

  function setIsRewardsClaimable(bool _isRewardsClaimable) internal {
    RewardStorage storage rewardStorage = getStorage();
    uint256 earliestRewardsClaimableTimestamp =
      Timestamp.unwrap(rewardStorage.earliestRewardsClaimableTimestamp.decompress());
    require(
      block.timestamp >= earliestRewardsClaimableTimestamp,
      Errors.Rollup__TooSoonToSetRewardsClaimable(earliestRewardsClaimableTimestamp, block.timestamp)
    );

    rewardStorage.isRewardsClaimable = _isRewardsClaimable;
  }

  function claimSequencerRewards(address _sequencer) internal returns (uint256) {
    RewardStorage storage rewardStorage = getStorage();
    require(rewardStorage.isRewardsClaimable, Errors.Rollup__RewardsNotClaimable());

    RollupStore storage rollupStore = STFLib.getStorage();
    uint256 amount = rewardStorage.sequencerRewards[_sequencer];

    if (amount > 0) {
      rewardStorage.sequencerRewards[_sequencer] = 0;
      rollupStore.config.feeAsset.safeTransfer(_sequencer, amount);
    }

    return amount;
  }

  function claimProverRewards(address _prover, Epoch[] memory _epochs) internal returns (uint256) {
    Epoch currentEpoch = Timestamp.wrap(block.timestamp).epochFromTimestamp();
    RollupStore storage rollupStore = STFLib.getStorage();

    RewardStorage storage rewardStorage = getStorage();

    require(rewardStorage.isRewardsClaimable, Errors.Rollup__RewardsNotClaimable());

    uint256 accumulatedRewards = 0;
    for (uint256 i = 0; i < _epochs.length; i++) {
      require(
        !_epochs[i].isAcceptingProofsAtEpoch(currentEpoch),
        Errors.Rollup__NotPastDeadline(_epochs[i].toDeadlineEpoch(), currentEpoch)
      );

      if (rewardStorage.proverClaimed[_prover].get(Epoch.unwrap(_epochs[i]))) {
        continue;
      }
      rewardStorage.proverClaimed[_prover].set(Epoch.unwrap(_epochs[i]));

      EpochRewards storage e = rewardStorage.epochRewards[_epochs[i]];
      SubEpochRewards storage se = e.subEpoch[e.longestProvenLength];
      uint256 shares = se.shares[_prover];
      if (shares > 0) {
        accumulatedRewards += (shares * e.rewards / se.summedShares);
      }
    }

    if (accumulatedRewards > 0) {
      rollupStore.config.feeAsset.safeTransfer(_prover, accumulatedRewards);
    }

    return accumulatedRewards;
  }

  function handleRewardsAndFees(SubmitEpochRootProofArgs memory _args, Epoch _endEpoch) internal {
    RollupStore storage rollupStore = STFLib.getStorage();
    RewardStorage storage rewardStorage = getStorage();

    // Determine if this rollup is canonical according to its RewardDistributor.

    uint256 length = _args.end - _args.start + 1;
    EpochRewards storage $er = rewardStorage.epochRewards[_endEpoch];

    {
      SubEpochRewards storage $sr = $er.subEpoch[length];
      address prover = _args.args.proverId;

      require($sr.shares[prover] == 0, Errors.Rollup__ProverHaveAlreadySubmitted(prover, _endEpoch));
      // Beware that it is possible to get marked active in an epoch even if you did not provide the longest
      // proof. This is acceptable, as they were actually active. And boosting this way is not the most
      // efficient way to do it, so this is fine.
      uint256 shares = rewardStorage.config.booster.updateAndGetShares(prover);

      $sr.shares[prover] = shares;
      $sr.summedShares += shares;
    }

    if (length > $er.longestProvenLength) {
      Values memory v;
      Totals memory t;

      {
        uint256 added = length - $er.longestProvenLength;
        uint256 blockRewardsDesired = added * getBlockReward();
        uint256 blockRewardsAvailable = 0;

        // Only if we require block rewards and are canonical will we claim.
        if (blockRewardsDesired > 0) {
          // Cache the reward distributor contract
          IRewardDistributor distributor = rewardStorage.config.rewardDistributor;

          if (address(this) == distributor.canonicalRollup()) {
            uint256 amountToClaim =
              Math.min(blockRewardsDesired, rollupStore.config.feeAsset.balanceOf(address(distributor)));

            if (amountToClaim > 0) {
              distributor.claim(address(this), amountToClaim);
              blockRewardsAvailable = amountToClaim;
            }
          }
        }

        uint256 sequenceBlockRewards = BpsLib.mul(blockRewardsAvailable, rewardStorage.config.sequencerBps);
        v.sequencerBlockReward = sequenceBlockRewards / added;

        $er.rewards += (blockRewardsAvailable - sequenceBlockRewards).toUint128();
      }

      bool isTxsEnabled = FeeLib.isTxsEnabled();

      for (uint256 i = $er.longestProvenLength; i < length; i++) {
        if (isTxsEnabled) {
          // During ignition there can be no txs, so there can be no fees either
          // so we can skip the fee calculation

          CompressedFeeHeader feeHeader = STFLib.getFeeHeader(_args.start + i);

          v.manaUsed = feeHeader.getManaUsed();

          uint256 fee = uint256(_args.fees[1 + i * 2]);
          uint256 burn = feeHeader.getCongestionCost() * v.manaUsed;

          t.feesToClaim += fee;
          t.totalBurn += burn;

          // Compute the proving fee in the fee asset
          v.proverFee = Math.min(v.manaUsed * feeHeader.getProverCost(), fee - burn);
          $er.rewards += v.proverFee.toUint128();

          v.sequencerFee = fee - burn - v.proverFee;
        }

        {
          v.sequencer = fieldToAddress(_args.fees[i * 2]);
          rewardStorage.sequencerRewards[v.sequencer] += (v.sequencerBlockReward + v.sequencerFee);
        }
      }

      $er.longestProvenLength = length.toUint128();

      if (t.feesToClaim > 0) {
        rollupStore.config.feeAssetPortal.distributeFees(address(this), t.feesToClaim);
      }

      if (t.totalBurn > 0) {
        rollupStore.config.feeAsset.safeTransfer(BURN_ADDRESS, t.totalBurn);
      }
    }
  }

  function getSharesFor(address _prover) internal view returns (uint256) {
    return getStorage().config.booster.getSharesFor(_prover);
  }

  function getSequencerRewards(address _sequencer) internal view returns (uint256) {
    return getStorage().sequencerRewards[_sequencer];
  }

  function getCollectiveProverRewardsForEpoch(Epoch _epoch) internal view returns (uint256) {
    return getStorage().epochRewards[_epoch].rewards;
  }

  function getHasSubmitted(Epoch _epoch, uint256 _length, address _prover) internal view returns (bool) {
    return getStorage().epochRewards[_epoch].subEpoch[_length].shares[_prover] > 0;
  }

  function getHasClaimed(address _prover, Epoch _epoch) internal view returns (bool) {
    return getStorage().proverClaimed[_prover].get(Epoch.unwrap(_epoch));
  }

  function getBlockReward() internal view returns (uint256) {
    return getStorage().config.blockReward;
  }

  function getSpecificProverRewardsForEpoch(Epoch _epoch, address _prover) internal view returns (uint256) {
    RewardStorage storage rewardStorage = getStorage();

    if (rewardStorage.proverClaimed[_prover].get(Epoch.unwrap(_epoch))) {
      return 0;
    }

    EpochRewards storage er = rewardStorage.epochRewards[_epoch];
    SubEpochRewards storage se = er.subEpoch[er.longestProvenLength];

    // Only if prover has shares will he get a reward. Also avoid a 0-div
    // in case of no shares at all.
    if (se.shares[_prover] == 0) {
      return 0;
    }

    return (se.shares[_prover] * er.rewards / se.summedShares);
  }

  function isRewardsClaimable() internal view returns (bool) {
    return getStorage().isRewardsClaimable;
  }

  function getEarliestRewardsClaimableTimestamp() internal view returns (Timestamp) {
    return getStorage().earliestRewardsClaimableTimestamp.decompress();
  }

  function getStorage() internal pure returns (RewardStorage storage storageStruct) {
    bytes32 position = REWARD_STORAGE_POSITION;
    assembly {
      storageStruct.slot := position
    }
  }

  function fieldToAddress(bytes32 _f) private pure returns (address) {
    return address(uint160(uint256(_f)));
  }
}


// File: lib/l1-contracts/src/core/libraries/StakingQueue.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27;

import {G1Point, G2Point} from "@aztec/shared/libraries/BN254Lib.sol";
import {Errors} from "./Errors.sol";

/**
 * @notice A struct containing the arguments needed for GSE.deposit(...) function
 * @dev Used to store validator information in the entry queue before they are processed
 */
struct DepositArgs {
  address attester;
  address withdrawer;
  G1Point publicKeyInG1;
  G2Point publicKeyInG2;
  G1Point proofOfPossession;
  bool moveWithLatestRollup;
}

/**
 * @notice A queue data structure for managing validator deposits
 * @dev Implements a FIFO queue using a mapping and two pointers
 * @param validators Mapping from queue index to validator deposit arguments
 * @param first Index of the first element in the queue (head)
 * @param last Index of the next available slot in the queue (tail)
 */
struct StakingQueue {
  mapping(uint256 index => DepositArgs validator) validators;
  uint128 first;
  uint128 last;
}

library StakingQueueLib {
  function init(StakingQueue storage self) internal {
    self.first = 1;
    self.last = 1;
  }

  function enqueue(
    StakingQueue storage self,
    address _attester,
    address _withdrawer,
    G1Point memory _publicKeyInG1,
    G2Point memory _publicKeyInG2,
    G1Point memory _proofOfPossession,
    bool _moveWithLatestRollup
  ) internal returns (uint256) {
    uint128 queueLocation = self.last;

    self.validators[queueLocation] = DepositArgs({
      attester: _attester,
      withdrawer: _withdrawer,
      publicKeyInG1: _publicKeyInG1,
      publicKeyInG2: _publicKeyInG2,
      proofOfPossession: _proofOfPossession,
      moveWithLatestRollup: _moveWithLatestRollup
    });
    self.last = queueLocation + 1;

    return queueLocation;
  }

  function dequeue(StakingQueue storage self) internal returns (DepositArgs memory validator) {
    require(self.last > self.first, Errors.Staking__QueueEmpty());

    validator = self.validators[self.first];

    self.first += 1;
  }

  function length(StakingQueue storage self) internal view returns (uint256 len) {
    len = self.last - self.first;
  }

  function at(StakingQueue storage self, uint256 index) internal view returns (DepositArgs memory validator) {
    validator = self.validators[self.first + index];
  }
}


// File: lib/l1-contracts/src/core/RollupCore.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
// solhint-disable imports-order
pragma solidity >=0.8.27;

import {IFeeJuicePortal} from "@aztec/core/interfaces/IFeeJuicePortal.sol";
import {
  IRollupCore, RollupStore, SubmitEpochRootProofArgs, RollupConfigInput
} from "@aztec/core/interfaces/IRollup.sol";
import {IVerifier} from "@aztec/core/interfaces/IVerifier.sol";
import {IStakingCore} from "@aztec/core/interfaces/IStaking.sol";
import {IValidatorSelectionCore} from "@aztec/core/interfaces/IValidatorSelection.sol";
import {IInbox} from "@aztec/core/interfaces/messagebridge/IInbox.sol";
import {IOutbox} from "@aztec/core/interfaces/messagebridge/IOutbox.sol";
import {Constants} from "@aztec/core/libraries/ConstantsGen.sol";
import {CommitteeAttestations} from "@aztec/core/libraries/rollup/AttestationLib.sol";
import {Errors} from "@aztec/core/libraries/Errors.sol";
import {RollupOperationsExtLib} from "@aztec/core/libraries/rollup/RollupOperationsExtLib.sol";
import {ValidatorOperationsExtLib} from "@aztec/core/libraries/rollup/ValidatorOperationsExtLib.sol";
import {TallySlasherDeploymentExtLib} from "@aztec/core/libraries/rollup/TallySlasherDeploymentExtLib.sol";
import {EmpireSlasherDeploymentExtLib} from "@aztec/core/libraries/rollup/EmpireSlasherDeploymentExtLib.sol";
import {SlasherFlavor} from "@aztec/core/interfaces/ISlasher.sol";
import {EthValue, FeeLib} from "@aztec/core/libraries/rollup/FeeLib.sol";
import {ProposeArgs} from "@aztec/core/libraries/rollup/ProposeLib.sol";
import {STFLib, GenesisState} from "@aztec/core/libraries/rollup/STFLib.sol";
import {StakingLib} from "@aztec/core/libraries/rollup/StakingLib.sol";
import {Timestamp, Slot, Epoch, TimeLib} from "@aztec/core/libraries/TimeLib.sol";
import {Inbox} from "@aztec/core/messagebridge/Inbox.sol";
import {Outbox} from "@aztec/core/messagebridge/Outbox.sol";
import {ISlasher} from "@aztec/core/slashing/Slasher.sol";
import {GSE} from "@aztec/governance/GSE.sol";
import {Ownable} from "@oz/access/Ownable.sol";
import {IERC20} from "@oz/token/ERC20/IERC20.sol";
import {EIP712} from "@oz/utils/cryptography/EIP712.sol";
import {RewardExtLib, RewardConfig} from "@aztec/core/libraries/rollup/RewardExtLib.sol";
import {StakingQueueConfig} from "@aztec/core/libraries/compressed-data/StakingQueueConfig.sol";
import {FeeConfigLib, CompressedFeeConfig} from "@aztec/core/libraries/compressed-data/fees/FeeConfig.sol";
import {G1Point, G2Point} from "@aztec/shared/libraries/BN254Lib.sol";
import {ChainTipsLib, CompressedChainTips} from "@aztec/core/libraries/compressed-data/Tips.sol";
import {Signature} from "@aztec/shared/libraries/SignatureLib.sol";

/**
 * @title RollupCore
 * @author Aztec Labs
 * @notice Core Aztec rollup contract that manages the L2 blockchain state, validator selection, and proof verification.
 *
 * @dev This is the main contract in the Aztec system that handles:
 *      - Block proposals from sequencers/proposers
 *      - Epoch proof submission and verification
 *      - Chain pruning and invalidation mechanisms
 *      - Validator and committee management
 *      - Fee collection and reward distribution
 *
 *      The rollup operates on a time-based model:
 *      - Time is divided into slots (configurable duration, e.g., 12 seconds)
 *      - Slots are grouped into epochs (configurable size, e.g., 32 slots)
 *      - Each slot has one designated proposer from the validator set
 *      - Each block is expected to include attestations from committee members
 *      - There is one committee per epoch
 *
 *      Key invariants:
 *      - The L2 chain is linear (no forks) but can be rolled back
 *        - New blocks must build on the state of the current pending block
 *      - Blocks with invalid attestations can be removed via the invalidation mechanism
 *      - Unproven blocks are pruned if no proof is submitted in time
 *
 * @dev Due to contract size limitations, not all functionality can be implemented in a single contract, so features
 *      are split across multiple ExtRollup external libraries.
 *
 * @dev System Roles
 *
 *      1) Validators: Node operators who have staked the staking asset and actively participate in block building.
 *         They form the pool from which committee members and proposers are selected.
 *
 *      2) Committee Members: Drafted from the validator set and remain stable throughout an epoch.
 *         A block requires >2/3rds of the committee for the epoch to be considered valid. These attestations serve two
 *         purposes:
 *         - Attest to data availability for transaction data not posted on L1, which is required by provers to generate
 *           epoch proofs
 *         - Re-execute everything and attest to the resulting state root, acting as training wheels for the public
 *           part of the system (proving systems used in public and AVM)
 *
 *      3) Proposers: Drafted from the validator set (currently proposers are part of the committee for the epoch,
 *         though this may change). They have exclusive rights to propose a block at a given slot, ensuring orderly
 *         block production without competition.
 *
 *      4) Provers: Generate validity proofs for the state transitions of blocks in an epoch. No need to stake to be a
 *         prover. They have access to large amounts of compute.
 *
 * @dev Block Building Flow
 *
 *      Relevant functions:
 *      - `propose`: Called by the proposer to submit a new block
 *      - `submitEpochRootProof`: Called by the prover to submit a proof of the epoch's state transitions
 *      - `invalidateBadAttestation`: Called to remove blocks with invalid attestations
 *      - `invalidateInsufficientAttestations`: Called to remove blocks with insufficient valid attestations
 *      - `prune`: Called to remove unproven blocks after the proof submission window has expired
 *      - `setupEpoch`: Called to initialize the validator selection for the next epoch
 *
 *      The block building flow is as follows:
 *
 *      - At each L2 slot a single proposer is chosen from the validator set who assembles a block that:
 *         - Builds on top of the last pending block (tips.pending) in the rollup
 *         - Includes state transitions, messages, and fee calculations
 *         - Is attested by >2/3 of the committee members
 *      - The L2 block is posted to L1 via the `propose` function
 *         - The pending chain tip advances to the new block
 *         - State is updated (message trees, archives, etc.)
 *      - After the epoch has ended, a prover generates a proof of the valid state transition for a prefix of blocks in
 *        the epoch
 *         - Most often the prefix will be all the blocks, but "partial epochs" can also be proven for faster message
 *           transmission
 *         - The proof is submitted via `submitEpochRootProof` and must be submitted within the configured proof
 *           submission window
 *         - Upon successful proof submission the proven chain tip advances to the last block in the proven prefix if it
 *           is past the current proven tip, otherwise the tip remain unchanged
 *         - It is possible to submit multiple proofs for the same epoch (or prefixes of it)
 *         - Provers of longest prefix shares the proving rewards
 *      - Proving a block makes it finalized from the perspective of L1
 *         - This triggers reward and fee accounting for the sequencers and provers of the epoch
 *         - And pushes messages to the outbox for L1 processing
 *
 *      Unhappy path for invalid attestations:
 *      - Attestations in blocks are not validated on-chain to save gas. Since attestations are still posted to L1,
 *        nodes are expected to verify them off-chain, and skip a block if its attestations are invalid.
 *      - If a block has invalid attestation signatures, anyone can call `invalidateBadAttestation()`
 *      - If a block has insufficient valid attestations (<= 2/3 of committee), anyone can call
 *        `invalidateInsufficientAttestations()`
 *      - While anyone can call invalidation functions, it is expected that the next proposer will do so, and if they
 *        fail to do so, then other committee members do, and if they fail to do so, then any validator will do so.
 *      - Upon invalidation, the invalid block and all subsequent blocks are removed from the chain, so the pending
 *        chain tip reverts to the block immediately before the invalid one.
 *       - Note that only unproven blocks can be invalidated, as proven blocks are final and cannot be reverted.
 *
 *      Unhappy path for missing proofs:
 *      - Each epoch has a proof submission window (configured via aztecProofSubmissionEpochs).
 *      - If no proof is submitted within the window, it is assumed that the epoch cannot be proven due to missing data,
 *        so the entire pending chain all the way back to the last proven block is pruned. This is done by calling
 *        `prune()` manually, or automatically on the next proposal.
 *      - The committee for the epoch is expected to disseminate transaction data to allow proving, so a prune is
 *        considered a slashable offense, that causes validators to vote for slashing the committee of the unproven
 *        epoch.
 *      - When the pending chain is pruned, all unproven blocks are removed from the pending chain, and the chain
 *        resumes from the last proven block.
 *
 * @dev Slashing Mechanism
 *
 *      Slashing is a critical security mechanism that penalizes validators who misbehave or fail to fulfill their
 *      duties. Slashing occurs for both safety violations (e.g., invalid attestations) and liveness failures
 *      (e.g., missing proofs). The slashing process is governance-based and operates through a signalling mechanism:
 *
 *      - When nodes detect validator misbehavior, they create a payload for slashing the offending validators
 *      - The payload is submitted to the SlashingProposer contract, which keeps track of signalling rounds
 *      - Each block proposer signals on a slashing payload during their assigned slot
 *      - If the payload receives sufficient signals (reaches the configured quorum) within a round, it may be submitted
 *        for execution by the Slasher after a configured delay.
 *      - The Slasher has a Vetoer specified in the constructor, which can veto the payload if it is deemed to be
 *        invalid.
 *      - Once submitted to the Slasher, if the payload is not Vetoed, the offending validators are slashed, meaning
 *        their staked assets are reduced by the slashing amount
 *      - If a validator's stake falls below the minimum required amount due to slashing, they are automatically
 *        removed from the validator set
 *
 *      Conditions that cause nodes to vote for slashing a validator:
 *      1. Validators that fail to fulfill their duties:
 *         - Committee members who fail to attest to blocks when required
 *      2. Committee members of an unproven epoch where either:
 *         - The data for the epoch is not available
 *         - The the epoch was provable but no proof was submitted
 *      3. Proposers of invalid blocks or committee members who attest to blocks built on top of invalid ones:
 *         - Proposing blocks with invalid state transitions
 *         - Proposing blocks with invalid attestations
 *         - Attesting to blocks that build upon known invalid blocks (e.g. invalid attestations)
 *         - This ensures the integrity of the chain by penalizing those who contribute to invalid blocks
 */
contract RollupCore is EIP712("Aztec Rollup", "1"), Ownable, IStakingCore, IValidatorSelectionCore, IRollupCore {
  using TimeLib for Timestamp;
  using TimeLib for Slot;
  using TimeLib for Epoch;
  using FeeConfigLib for CompressedFeeConfig;
  using ChainTipsLib for CompressedChainTips;

  /**
   * @notice The L1 block number when this rollup was deployed
   * @dev Used when synching the node as starting block for event watching
   */
  uint256 public immutable L1_BLOCK_AT_GENESIS;

  /**
   * @dev Storage gap to ensure checkBlob is in its own storage slot
   */
  uint256 private gap = 0;

  /**
   * @notice Flag to enable/disable blob verification during simulations
   * @dev Always true, gets unset only via state overrides during off-chain simulations or in tests
   */
  bool public checkBlob = true;

  /**
   * @notice Initializes the Aztec rollup with all required configurations
   * @dev Sets up time parameters, deploys auxiliary contracts (slasher, reward booster),
   *      initializes staking, validator selection, and creates inbox/outbox contracts
   * @param _feeAsset The ERC20 token used for transaction fees
   * @param _stakingAsset The ERC20 token used for validator staking
   * @param _gse The Governance Staking Escrow contract
   * @param _epochProofVerifier The honk verifier contract for root epoch proofs
   * @param _governance The address with owner privileges
   * @param _genesisState Initial state containing VK tree root, protocol contracts hash, and genesis archive
   * @param _config Comprehensive configuration including timing, staking, slashing, reward parameters, and unlock
   * timestamp
   */
  constructor(
    IERC20 _feeAsset,
    IERC20 _stakingAsset,
    GSE _gse,
    IVerifier _epochProofVerifier,
    address _governance,
    GenesisState memory _genesisState,
    RollupConfigInput memory _config
  ) Ownable(_governance) {
    // We do not allow the `normalFlushSizeMin` to be 0 when deployed as it would lock deposits (which is never desired
    // from the onset). It might be updated later to 0 by governance in order to close the validator set for this
    // instance. For details see `StakingLib.getEntryQueueFlushSize` function.
    require(_config.stakingQueueConfig.normalFlushSizeMin > 0, Errors.Staking__InvalidStakingQueueConfig());
    require(_config.stakingQueueConfig.normalFlushSizeQuotient > 0, Errors.Staking__InvalidNormalFlushSizeQuotient());

    TimeLib.initialize(
      block.timestamp, _config.aztecSlotDuration, _config.aztecEpochDuration, _config.aztecProofSubmissionEpochs
    );

    Timestamp exitDelay = Timestamp.wrap(_config.exitDelaySeconds);

    // Deploy slasher based on flavor
    ISlasher slasher;

    // We call one external library or another based on the slasher flavor
    // This allows us to keep the slash flavors in separate external libraries so we do not exceed max contract size
    // Note that we do not deploy a slasher if we run with no committees (i.e. targetCommitteeSize == 0)
    if (_config.targetCommitteeSize == 0 || _config.slasherFlavor == SlasherFlavor.NONE) {
      slasher = ISlasher(address(0));
    } else if (_config.slasherFlavor == SlasherFlavor.TALLY) {
      slasher = TallySlasherDeploymentExtLib.deployTallySlasher(
        address(this),
        _config.slashingVetoer,
        _governance,
        _config.slashingQuorum,
        _config.slashingRoundSize,
        _config.slashingLifetimeInRounds,
        _config.slashingExecutionDelayInRounds,
        _config.slashAmounts,
        _config.targetCommitteeSize,
        _config.aztecEpochDuration,
        _config.slashingOffsetInRounds,
        _config.slashingDisableDuration
      );
    } else {
      slasher = EmpireSlasherDeploymentExtLib.deployEmpireSlasher(
        address(this),
        _config.slashingVetoer,
        _governance,
        _config.slashingQuorum,
        _config.slashingRoundSize,
        _config.slashingLifetimeInRounds,
        _config.slashingExecutionDelayInRounds,
        _config.slashingDisableDuration
      );
    }

    StakingLib.initialize(
      _stakingAsset, _gse, exitDelay, address(slasher), _config.stakingQueueConfig, _config.localEjectionThreshold
    );
    ValidatorOperationsExtLib.initializeValidatorSelection(_config.targetCommitteeSize, _config.lagInEpochs);

    // If no booster is specifically provided, deploy one.
    if (address(_config.rewardConfig.booster) == address(0)) {
      _config.rewardConfig.booster = RewardExtLib.deployRewardBooster(_config.rewardBoostConfig);
    }

    RewardExtLib.initialize(_config.earliestRewardsClaimableTimestamp);
    RewardExtLib.setConfig(_config.rewardConfig);

    L1_BLOCK_AT_GENESIS = block.number;

    STFLib.initialize(_genesisState);
    RollupStore storage rollupStore = STFLib.getStorage();

    rollupStore.config.feeAsset = _feeAsset;
    rollupStore.config.epochProofVerifier = _epochProofVerifier;

    uint32 version = _config.version;
    rollupStore.config.version = version;

    IInbox inbox = IInbox(address(new Inbox(address(this), _feeAsset, version, Constants.L1_TO_L2_MSG_SUBTREE_HEIGHT)));

    rollupStore.config.inbox = inbox;

    rollupStore.config.outbox = IOutbox(address(new Outbox(address(this), version)));

    rollupStore.config.feeAssetPortal = IFeeJuicePortal(inbox.getFeeAssetPortal());

    FeeLib.initialize(_config.manaTarget, _config.provingCostPerMana);
  }

  /**
   * @notice Updates the reward configuration for sequencers and provers
   * @dev Only callable by the contract owner. Updates how rewards are calculated and distributed.
   * @param _config The new reward configuration including rates and booster settings
   */
  function setRewardConfig(RewardConfig memory _config) external override(IRollupCore) onlyOwner {
    RewardExtLib.setConfig(_config);
    emit RewardConfigUpdated(_config);
  }

  /**
   * @notice Updates the target mana (computational units) per slot
   * @dev Only callable by owner. The new target must be greater than or equal to the current target
   *      to avoid the ability for governance to use it directly to kill an old rollup.
   *      Mana is the unit of computational work in Aztec.
   * @param _manaTarget The new target mana per slot
   */
  function updateManaTarget(uint256 _manaTarget) external override(IRollupCore) onlyOwner {
    uint256 currentManaTarget = FeeLib.getStorage().config.getManaTarget();
    require(_manaTarget >= currentManaTarget, Errors.Rollup__InvalidManaTarget(currentManaTarget, _manaTarget));
    FeeLib.updateManaTarget(_manaTarget);

    // If we are going from 0 to non-zero mana limits, we need to catch up the inbox
    if (currentManaTarget == 0 && _manaTarget > 0) {
      RollupStore storage rollupStore = STFLib.getStorage();
      rollupStore.config.inbox.catchUp(rollupStore.tips.getPendingBlockNumber());
    }

    emit IRollupCore.ManaTargetUpdated(_manaTarget);
  }

  /**
   * @notice Enables or disables reward claiming
   * @dev Only callable by owner. This is a safety mechanism to control when rewards can be withdrawn.
   *      Cannot set rewards as claimable before the earliest reward claimable timestamp.
   * @param _isRewardsClaimable True to enable reward claims, false to disable
   */
  function setRewardsClaimable(bool _isRewardsClaimable) external override(IRollupCore) onlyOwner {
    RewardExtLib.setIsRewardsClaimable(_isRewardsClaimable);
    emit RewardsClaimableUpdated(_isRewardsClaimable);
  }

  /**
   * @notice Updates the slasher contract address
   * @dev Only callable by owner. The slasher handles punishment for validator misbehavior.
   * @param _slasher The address of the new slasher contract
   */
  function setSlasher(address _slasher) external override(IStakingCore) onlyOwner {
    ValidatorOperationsExtLib.setSlasher(_slasher);
  }

  /**
   * @notice Updates the local ejection threshold
   * @dev Only callable by owner. The local ejection threshold is the minimum amount of stake that a validator can have
   *      after being slashed.
   * @param _localEjectionThreshold The new local ejection threshold
   */
  function setLocalEjectionThreshold(uint256 _localEjectionThreshold) external override(IStakingCore) onlyOwner {
    ValidatorOperationsExtLib.setLocalEjectionThreshold(_localEjectionThreshold);
  }

  /**
   * @notice Updates the cost of proving per unit of mana
   * @dev Only callable by owner. This affects how proving costs are calculated in the fee model.
   * @param _provingCostPerMana The cost in ETH per unit of mana for proving
   */
  function setProvingCostPerMana(EthValue _provingCostPerMana) external override(IRollupCore) onlyOwner {
    FeeLib.updateProvingCostPerMana(_provingCostPerMana);
  }

  /**
   * @notice Updates the configuration for the staking entry queue
   * @dev Only callable by owner. Controls how validators enter the active set.
   * @param _config New configuration including queue size limits and timing parameters
   */
  function updateStakingQueueConfig(StakingQueueConfig memory _config) external override(IStakingCore) onlyOwner {
    ValidatorOperationsExtLib.updateStakingQueueConfig(_config);
  }

  /**
   * @notice Claims accumulated rewards for a sequencer (block proposer)
   * @dev Rewards must be enabled via isRewardsClaimable. Transfers all accumulated rewards to the recipient.
   * @param _coinbase The address that has accumulated the rewards - rewards are sent to this address
   * @return The amount of rewards claimed
   */
  function claimSequencerRewards(address _coinbase) external override(IRollupCore) returns (uint256) {
    return RewardExtLib.claimSequencerRewards(_coinbase);
  }

  /**
   * @notice Claims prover rewards for specified epochs
   * @dev Rewards must be enabled. Provers earn rewards for successfully proving epoch transitions.
   *      Each epoch can only be claimed once per prover.
   * @param _coinbase The address that has accumulated the rewards - rewards are sent to this address
   * @param _epochs Array of epochs to claim rewards for
   * @return The total amount of rewards claimed
   */
  function claimProverRewards(address _coinbase, Epoch[] memory _epochs)
    external
    override(IRollupCore)
    returns (uint256)
  {
    return RewardExtLib.claimProverRewards(_coinbase, _epochs);
  }

  /**
   * @notice Allows the rollup itself to vote on governance proposals
   * @dev This enables the rollup to participate in governance by voting on proposals.
   *      See StakingLib.sol for more details on the voting mechanism.
   * @param _proposalId The ID of the proposal to vote on
   */
  function vote(uint256 _proposalId) external override(IStakingCore) {
    ValidatorOperationsExtLib.vote(_proposalId);
  }

  /**
   * @notice Deposits stake to become a validator
   * @dev The caller must have approved the staking asset. Validators enter a queue before becoming active.
   * @param _attester The address that will act as the validator (sign attestations)
   * @param _withdrawer The address that can withdraw the stake
   * @param _publicKeyInG1 The G1 point for the BLS public key (used for efficient signature verification in GSE)
   * @param _publicKeyInG2 The G2 point for the BLS public key (used for BLS aggregation and pairing operations in GSE)
   * @param _proofOfPossession The proof of possession to show that the keys in G1 and G2 share secret key
   * @param _moveWithLatestRollup Whether to follow the chain if governance migrates to a new rollup version
   */
  function deposit(
    address _attester,
    address _withdrawer,
    G1Point memory _publicKeyInG1,
    G2Point memory _publicKeyInG2,
    G1Point memory _proofOfPossession,
    bool _moveWithLatestRollup
  ) external override(IStakingCore) {
    ValidatorOperationsExtLib.deposit(
      _attester, _withdrawer, _publicKeyInG1, _publicKeyInG2, _proofOfPossession, _moveWithLatestRollup
    );
  }

  /**
   * @notice Processes the validator entry queue to add new validators to the active set
   * @dev Can be called by anyone. The number of validators added is limited by queue configuration.
   *      This helps maintain a controlled growth rate of the validator set.
   * @param _toAdd - The max number the caller will try to add
   */
  function flushEntryQueue(uint256 _toAdd) external override(IStakingCore) {
    ValidatorOperationsExtLib.flushEntryQueue(_toAdd);
  }

  function flushEntryQueue() external override(IStakingCore) {
    ValidatorOperationsExtLib.flushEntryQueue(type(uint256).max);
  }

  /**
   * @notice Initiates withdrawal of a validator's stake
   * @dev Starts the exit delay period. The validator is immediately removed from the active set.
   *      Only the registered withdrawer can initiate withdrawal.
   * @param _attester The validator address to withdraw
   * @param _recipient The address to receive the withdrawn stake
   * @return True if withdrawal was initiated, false if already initiated
   */
  function initiateWithdraw(address _attester, address _recipient) external override(IStakingCore) returns (bool) {
    return ValidatorOperationsExtLib.initiateWithdraw(_attester, _recipient);
  }

  /**
   * @notice Completes a withdrawal after the exit delay has passed
   * @dev Can be called by anyone. Transfers the stake to the designated recipient.
   * @param _attester The validator address whose withdrawal to finalize
   */
  function finalizeWithdraw(address _attester) external override(IStakingCore) {
    ValidatorOperationsExtLib.finalizeWithdraw(_attester);
  }

  /**
   * @notice Slashes a validator's stake for misbehavior
   * @dev Only callable by the authorized slasher contract. Reduces the validator's stake.
   * @param _attester The validator to slash
   * @param _amount The amount of stake to slash
   * @return True if slashing was successful
   */
  function slash(address _attester, uint256 _amount) external override(IStakingCore) returns (bool) {
    return ValidatorOperationsExtLib.slash(_attester, _amount);
  }

  /**
   * @notice Removes unproven blocks from the pending chain
   * @dev Can only be called after the proof submission window has expired for an epoch.
   *      This maintains liveness by preventing the chain from being stuck on unproven blocks.
   *      Pruning occurs at epoch boundaries and removes all blocks in unproven epochs.
   */
  function prune() external override(IRollupCore) {
    RollupOperationsExtLib.prune();
  }

  /**
   * @notice Submits a zero-knowledge proof for an epoch's state transition
   * @dev Proves the validity of a prefix of the blocks in an epoch. Once proven, blocks become final
   *      and cannot be pruned. The proof must be submitted within the submission window.
   *      Successful submission triggers prover rewards.
   * @param _args Contains the epoch range, public inputs, fees, attestations, and the ZK proof
   */
  function submitEpochRootProof(SubmitEpochRootProofArgs calldata _args) external override(IRollupCore) {
    RollupOperationsExtLib.submitEpochRootProof(_args);
  }

  /**
   * @notice Proposes a new L2 block to extend the chain
   * @dev Core function for block production.
   *      The attestations must include a signature from designated proposer to be accepted.
   *      The block must build on the previous block and include valid attestations from committee members.
   *      Failed proposals revert; successful ones emit L2BlockProposed and advance the chain state.
   *      See ProposeLib#propose for more details.
   * @param _args Block data including header, state updates, oracle inputs, and archive
   * @param _attestations Aggregated signatures from committee members attesting to block validity
   * @param _signers Addresses of committee members who signed (must match attestations)
   * @param _blobInput Blob commitment data for data availability (format: [numBlobs][48-byte commitments...])
   */
  function propose(
    ProposeArgs calldata _args,
    CommitteeAttestations memory _attestations,
    address[] calldata _signers,
    Signature calldata _attestationsAndSignersSignature,
    bytes calldata _blobInput
  ) external override(IRollupCore) {
    RollupOperationsExtLib.propose(
      _args, _attestations, _signers, _attestationsAndSignersSignature, _blobInput, checkBlob
    );
  }

  /**
   * @notice Invalidates a block due to a bad attestation signature
   * @dev Anyone can call this if they detect an invalid signature. This removes the block
   *      and all subsequent blocks from the pending chain. Used to maintain pending chain integrity.
   * @param _blockNumber The L2 block number to invalidate
   * @param _attestations The attestations that were submitted with the block
   * @param _committee The committee members for the block's epoch
   * @param _invalidIndex The index of the invalid signature in the attestations
   */
  function invalidateBadAttestation(
    uint256 _blockNumber,
    CommitteeAttestations memory _attestations,
    address[] memory _committee,
    uint256 _invalidIndex
  ) external override(IRollupCore) {
    ValidatorOperationsExtLib.invalidateBadAttestation(_blockNumber, _attestations, _committee, _invalidIndex);
  }

  /**
   * @notice Invalidates a block due to insufficient valid attestations (>2/3 of committee required)
   * @dev Anyone can call this if a block doesn't meet the required attestation threshold.
   *      Even if all signatures are valid, blocks need a minimum number of attestations.
   * @param _blockNumber The L2 block number to invalidate
   * @param _attestations The attestations that were submitted with the block
   * @param _committee The committee members for the block's epoch
   */
  function invalidateInsufficientAttestations(
    uint256 _blockNumber,
    CommitteeAttestations memory _attestations,
    address[] memory _committee
  ) external override(IRollupCore) {
    ValidatorOperationsExtLib.invalidateInsufficientAttestations(_blockNumber, _attestations, _committee);
  }

  /**
   * @notice Sets up validator selection for the current epoch
   * @dev Can be called by anyone at the start of an epoch. Samples the committee and determines proposers for all
   *      slots in the epoch. Also stores a seed that is used for future sampling. The corresponding library
   *      functionality is automatically called when `RollupCore.propose(...)` is called (via the
   *      `RollupOperationsExtLib.propose(...)` -> `ProposeLib.propose(...)` ->
   *      `ValidatorSelectionLib.setupEpoch(...)`).
   *
   *      If there are missed proposals then setupEpoch does not get called automatically. Since the next committee
   *      selection is computed based on the stored randao and the epoch number, failing to update the randao stored
   *      will keep the committee predictable longer into the future. We would only fail to get a fresh randao if:
   *      1. All the proposals in the epoch were missed
   *      2. Nobody called setupEpoch on the Rollup contract
   *
   *      While an attacker might theoretically benefit from preventing a fresh seed (e.g. by DoSing all proposers),
   *      preventing anyone from calling this function directly is not really feasible. This makes attacks on seed
   *      generation impractical.
   */
  function setupEpoch() external override(IValidatorSelectionCore) {
    ValidatorOperationsExtLib.setupEpoch();
  }

  /**
   * @notice Captures the randao for future validator selection
   * @dev Can be called by anyone. Takes a snapshot of the current randao to ensure unpredictable but deterministic
   *      validator selection. Automatically called from setupEpoch. Can be used as a cheaper alternative to
   *      `setupEpoch` to update the randao checkpoints.
   */
  function checkpointRandao() public override(IValidatorSelectionCore) {
    ValidatorOperationsExtLib.checkpointRandao();
  }

  /**
   * @notice Updates the L1 gas fee oracle with current gas prices
   * @dev Automatically called during block proposal but can be called manually.
   *      Updates the fee model's view of L1 costs to ensure accurate L2 fee pricing.
   *      Uses current L1 gas price and blob gas price for calculations.
   */
  function updateL1GasFeeOracle() public override(IRollupCore) {
    FeeLib.updateL1GasFeeOracle();
  }

  /**
   * @notice Returns the maximum number of validators that can be added from the entry queue
   * @dev Based on queue configuration and current validator set size. Used by flushEntryQueue.
   * @return The number of validators that can be added in the next flush
   */
  function getEntryQueueFlushSize() public view override(IStakingCore) returns (uint256) {
    return ValidatorOperationsExtLib.getEntryQueueFlushSize();
  }

  /**
   * @notice Returns the current number of active validators
   * @dev Active validators can propose blocks and participate in committees
   * @return The count of validators in the active set
   */
  function getActiveAttesterCount() public view override(IStakingCore) returns (uint256) {
    return StakingLib.getAttesterCountAtTime(Timestamp.wrap(block.timestamp));
  }
}


// File: lib/l1-contracts/src/core/interfaces/IFeeJuicePortal.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {IRollup} from "@aztec/core/interfaces/IRollup.sol";
import {IERC20} from "@oz/token/ERC20/IERC20.sol";
import {IInbox} from "./messagebridge/IInbox.sol";

interface IFeeJuicePortal {
  event DepositToAztecPublic(bytes32 indexed to, uint256 amount, bytes32 secretHash, bytes32 key, uint256 index);
  event FeesDistributed(address indexed to, uint256 amount);

  function distributeFees(address _to, uint256 _amount) external;
  function depositToAztecPublic(bytes32 _to, uint256 _amount, bytes32 _secretHash) external returns (bytes32, uint256);

  // solhint-disable-next-line func-name-mixedcase
  function UNDERLYING() external view returns (IERC20);
  // solhint-disable-next-line func-name-mixedcase
  function L2_TOKEN_ADDRESS() external view returns (bytes32);
  // solhint-disable-next-line func-name-mixedcase
  function VERSION() external view returns (uint256);
  // solhint-disable-next-line func-name-mixedcase
  function INBOX() external view returns (IInbox);
  // solhint-disable-next-line func-name-mixedcase
  function ROLLUP() external view returns (IRollup);
}


// File: lib/l1-contracts/src/core/interfaces/ISlasher.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {IPayload} from "@aztec/governance/interfaces/IPayload.sol";

enum SlasherFlavor {
  NONE,
  TALLY,
  EMPIRE
}

interface ISlasher {
  event VetoedPayload(address indexed payload);
  event SlashingDisabled(uint256 disabledUntil);

  function slash(IPayload _payload) external returns (bool);
  function vetoPayload(IPayload _payload) external returns (bool);
  function setSlashingEnabled(bool _enabled) external;
  function isSlashingEnabled() external view returns (bool);
}


// File: lib/l1-contracts/src/core/interfaces/messagebridge/IInbox.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {DataStructures} from "../../libraries/DataStructures.sol";

/**
 * @title Inbox
 * @author Aztec Labs
 * @notice Lives on L1 and is used to pass messages into the rollup from L1.
 */
interface IInbox {
  struct InboxState {
    // Rolling hash of all messages inserted into the inbox.
    // Used by clients to check for consistency.
    bytes16 rollingHash;
    // This value is not used much by the contract, but it is useful for synching the node faster
    // as it can more easily figure out if it can just skip looking for events for a time period.
    uint64 totalMessagesInserted;
    // Number of a tree which is currently being filled
    uint64 inProgress;
  }

  /**
   * @notice Emitted when a message is sent
   * @param l2BlockNumber - The L2 block number in which the message is included
   * @param index - The index of the message in the L1 to L2 messages tree
   * @param hash - The hash of the message
   * @param rollingHash - The rolling hash of all messages inserted into the inbox
   */
  event MessageSent(uint256 indexed l2BlockNumber, uint256 index, bytes32 indexed hash, bytes16 rollingHash);

  event InboxSynchronized(uint256 indexed inProgress);

  // docs:start:send_l1_to_l2_message
  /**
   * @notice Inserts a new message into the Inbox
   * @dev Emits `MessageSent` with data for easy access by the sequencer
   * @param _recipient - The recipient of the message
   * @param _content - The content of the message (application specific)
   * @param _secretHash - The secret hash of the message (make it possible to hide when a specific message is consumed
   * on L2)
   * @return The key of the message in the set and its leaf index in the tree
   */
  function sendL2Message(DataStructures.L2Actor memory _recipient, bytes32 _content, bytes32 _secretHash)
    external
    returns (bytes32, uint256);
  // docs:end:send_l1_to_l2_message

  // docs:start:consume
  /**
   * @notice Consumes the current tree, and starts a new one if needed
   * @dev Only callable by the rollup contract
   * @dev In the first iteration we return empty tree root because first block's messages tree is always
   * empty because there has to be a 1 block lag to prevent sequencer DOS attacks
   *
   * @param _toConsume - The block number to consume
   *
   * @return The root of the consumed tree
   */
  function consume(uint256 _toConsume) external returns (bytes32);
  // docs:end:consume

  function catchUp(uint256 _pendingBlockNumber) external;

  function getFeeAssetPortal() external view returns (address);

  function getRoot(uint256 _blockNumber) external view returns (bytes32);

  function getState() external view returns (InboxState memory);

  function getTotalMessagesInserted() external view returns (uint64);

  function getInProgress() external view returns (uint64);
}


// File: lib/l1-contracts/src/core/interfaces/messagebridge/IOutbox.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {DataStructures} from "../../libraries/DataStructures.sol";

/**
 * @title IOutbox
 * @author Aztec Labs
 * @notice Lives on L1 and is used to consume L2 -> L1 messages. Messages are inserted by the Rollup
 * and will be consumed by the portal contracts.
 */
interface IOutbox {
  event RootAdded(uint256 indexed l2BlockNumber, bytes32 indexed root);
  event MessageConsumed(
    uint256 indexed l2BlockNumber, bytes32 indexed root, bytes32 indexed messageHash, uint256 leafId
  );

  // docs:start:outbox_insert
  /**
   * @notice Inserts the root of a merkle tree containing all of the L2 to L1 messages in
   * a block specified by _l2BlockNumber.
   * @dev Only callable by the rollup contract
   * @dev Emits `RootAdded` upon inserting the root successfully
   * @param _l2BlockNumber - The L2 Block Number in which the L2 to L1 messages reside
   * @param _root - The merkle root of the tree where all the L2 to L1 messages are leaves
   */
  function insert(uint256 _l2BlockNumber, bytes32 _root) external;
  // docs:end:outbox_insert

  // docs:start:outbox_consume
  /**
   * @notice Consumes an entry from the Outbox
   * @dev Only useable by portals / recipients of messages
   * @dev Emits `MessageConsumed` when consuming messages
   * @param _message - The L2 to L1 message
   * @param _l2BlockNumber - The block number specifying the block that contains the message we want to consume
   * @param _leafIndex - The index inside the merkle tree where the message is located
   * @param _path - The sibling path used to prove inclusion of the message, the _path length directly depends
   * on the total amount of L2 to L1 messages in the block. i.e. the length of _path is equal to the depth of the
   * L1 to L2 message tree.
   */
  function consume(
    DataStructures.L2ToL1Msg calldata _message,
    uint256 _l2BlockNumber,
    uint256 _leafIndex,
    bytes32[] calldata _path
  ) external;
  // docs:end:outbox_consume

  // docs:start:outbox_has_message_been_consumed_at_block_and_index
  /**
   * @notice Checks to see if an L2 to L1 message in a specific block has been consumed
   * @dev - This function does not throw. Out-of-bounds access is considered valid, but will always return false
   * @param _l2BlockNumber - The block number specifying the block that contains the message we want to check
   * @param _leafId - The unique id of the message leaf
   */
  function hasMessageBeenConsumedAtBlock(uint256 _l2BlockNumber, uint256 _leafId) external view returns (bool);
  // docs:end:outbox_has_message_been_consumed_at_block_and_index

  /**
   * @notice  Fetch the root data for a given block number
   *          Returns (0, 0) if the block is not proven
   *
   * @param _l2BlockNumber - The block number to fetch the root data for
   *
   * @return bytes32 - The root of the merkle tree containing the L2 to L1 messages
   */
  function getRootData(uint256 _l2BlockNumber) external view returns (bytes32);
}


// File: lib/l1-contracts/src/core/libraries/compressed-data/StakingQueueConfig.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27;

import {SafeCast} from "@oz/utils/math/SafeCast.sol";

type CompressedStakingQueueConfig is uint256;

/**
 * If the number of validators in the rollup is 0, and the number of validators in the queue is less than
 * `bootstrapValidatorSetSize`, then `getEntryQueueFlushSize` will return 0.
 *
 * If the number of validators in the rollup is 0, and the number of validators in the queue is greater than or equal to
 * `bootstrapValidatorSetSize`, then `getEntryQueueFlushSize` will return `bootstrapFlushSize`.
 *
 * If the number of validators in the rollup is greater than 0 and less than `bootstrapValidatorSetSize`, then
 * `getEntryQueueFlushSize` will return `bootstrapFlushSize`.
 *
 * If the number of validators in the rollup is greater than or equal to `bootstrapValidatorSetSize`, then
 * `getEntryQueueFlushSize` will return Max( `normalFlushSizeMin`, `activeAttesterCount` / `normalFlushSizeQuotient`).
 *
 * NOTE: If the normalFlushSizeMin is 0 and the validator set is empty, above will return max(0, 0) and it won't be
 * possible to add validators. This can close the queue even if there are members in the validator set if a very high
 * `normalFlushSizeQuotient` is used.
 *
 * NOTE: We will NEVER flush more than `maxQueueFlushSize` validators: it is applied as a Max at the end of every
 * calculation.
 * This can be used to prevent a situation where flushing the queue would exceed the block gas limit.
 */
struct StakingQueueConfig {
  uint256 bootstrapValidatorSetSize;
  uint256 bootstrapFlushSize;
  uint256 normalFlushSizeMin;
  uint256 normalFlushSizeQuotient;
  uint256 maxQueueFlushSize;
}

library StakingQueueConfigLib {
  using SafeCast for uint256;

  uint256 private constant MASK_32BIT = 0xFFFFFFFF;

  function compress(StakingQueueConfig memory _config) internal pure returns (CompressedStakingQueueConfig) {
    uint256 value = 0;
    value |= uint256(_config.maxQueueFlushSize.toUint32());
    value |= uint256(_config.normalFlushSizeQuotient.toUint32()) << 32;
    value |= uint256(_config.normalFlushSizeMin.toUint32()) << 64;
    value |= uint256(_config.bootstrapFlushSize.toUint32()) << 96;
    value |= uint256(_config.bootstrapValidatorSetSize.toUint32()) << 128;

    return CompressedStakingQueueConfig.wrap(value);
  }

  function decompress(CompressedStakingQueueConfig _compressedConfig) internal pure returns (StakingQueueConfig memory) {
    uint256 value = CompressedStakingQueueConfig.unwrap(_compressedConfig);

    return StakingQueueConfig({
      bootstrapValidatorSetSize: (value >> 128) & MASK_32BIT,
      bootstrapFlushSize: (value >> 96) & MASK_32BIT,
      normalFlushSizeMin: (value >> 64) & MASK_32BIT,
      normalFlushSizeQuotient: (value >> 32) & MASK_32BIT,
      maxQueueFlushSize: value & MASK_32BIT
    });
  }
}


// File: lib/l1-contracts/src/core/libraries/rollup/AttestationLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity ^0.8.27;

import {Errors} from "@aztec/core/libraries/Errors.sol";
import {Signature, SignatureLib} from "@aztec/shared/libraries/SignatureLib.sol";

uint256 constant SIGNATURE_LENGTH = 65; // v (1) + r (32) + s (32)
uint256 constant ADDRESS_LENGTH = 20;

/**
 * @notice The domain separator for the signatures
 */
enum SignatureDomainSeparator {
  blockProposal,
  blockAttestation,
  attestationsAndSigners
}

// A committee attestation can be made up of a signature and an address.
// Committee members that have attested will produce a signature, and if they have not attested, the signature will be
// empty and an address provided.
struct CommitteeAttestation {
  address addr;
  Signature signature;
}

struct CommitteeAttestations {
  // bitmap of which indices are signatures
  bytes signatureIndices;
  // tightly packed signatures and addresses
  bytes signaturesOrAddresses;
}

library AttestationLib {
  using SignatureLib for Signature;

  /**
   * @notice Checks if the given CommitteeAttestations is empty
   *          Wll return true if either component is empty as they are needed together.
   * @param _attestations - The committee attestations
   * @return True if the committee attestations are empty, false otherwise
   */
  function isEmpty(CommitteeAttestations memory _attestations) internal pure returns (bool) {
    return _attestations.signatureIndices.length == 0 || _attestations.signaturesOrAddresses.length == 0;
  }

  /**
   * @notice Checks if the given index in the CommitteeAttestations is a signature
   * @param _attestations - The committee attestations
   * @param _index - The index to check
   * @return True if the index is a signature, false otherwise
   *
   * @dev The signatureIndices is a bitmap of which indices are signatures.
   * The index is a signature if the bit at the index is 1.
   * The index is an address if the bit at the index is 0.
   *
   * See its use over in ValidatorSelectionLib.sol
   */
  function isSignature(CommitteeAttestations memory _attestations, uint256 _index) internal pure returns (bool) {
    uint256 byteIndex = _index / 8;
    uint256 shift = 7 - (_index % 8);
    return (uint8(_attestations.signatureIndices[byteIndex]) >> shift) & 1 == 1;
  }

  /**
   * @notice Gets the signature at the given index
   * @param _attestations - The committee attestations
   * @param _index - The index of the signature to get
   */
  function getSignature(CommitteeAttestations memory _attestations, uint256 _index)
    internal
    pure
    returns (Signature memory)
  {
    bytes memory signaturesOrAddresses = _attestations.signaturesOrAddresses;
    require(isSignature(_attestations, _index), Errors.AttestationLib__NotASignatureAtIndex(_index));

    uint256 dataPtr;
    assembly {
      // Skip length
      dataPtr := add(signaturesOrAddresses, 0x20)
    }

    // Move to the start of the signature
    for (uint256 i = 0; i < _index; ++i) {
      dataPtr += isSignature(_attestations, i) ? SIGNATURE_LENGTH : ADDRESS_LENGTH;
    }

    uint8 v;
    bytes32 r;
    bytes32 s;

    assembly {
      v := byte(0, mload(dataPtr))
      dataPtr := add(dataPtr, 1)
      r := mload(dataPtr)
      dataPtr := add(dataPtr, 32)
      s := mload(dataPtr)
    }
    return Signature({v: v, r: r, s: s});
  }

  /**
   * @notice Gets the address at the given index
   * @param _attestations - The committee attestations
   * @param _index - The index of the address to get
   */
  function getAddress(CommitteeAttestations memory _attestations, uint256 _index) internal pure returns (address) {
    bytes memory signaturesOrAddresses = _attestations.signaturesOrAddresses;
    require(!isSignature(_attestations, _index), Errors.AttestationLib__NotAnAddressAtIndex(_index));

    uint256 dataPtr;
    assembly {
      // Skip length
      dataPtr := add(signaturesOrAddresses, 0x20)
    }

    // Move to the start of the signature
    for (uint256 i = 0; i < _index; ++i) {
      dataPtr += isSignature(_attestations, i) ? SIGNATURE_LENGTH : ADDRESS_LENGTH;
    }

    address addr;
    assembly {
      addr := shr(96, mload(dataPtr))
    }

    return addr;
  }

  /**
   * Recovers the committee from the addresses in the attestations and signers.
   *
   * @custom:reverts SignatureIndicesSizeMismatch if the signature indices have a wrong size
   * @custom:reverts OutOfBounds throws if reading data beyond the `_attestations`
   * @custom:reverts SignaturesOrAddressesSizeMismatch if the signatures or addresses object has wrong size
   *
   * @param _attestations - The committee attestations
   * @param _signers The addresses of the committee members that signed the attestations. Provided in order to not have
   * to recover them from their attestations' signatures (and hence save gas). The addresses of the non-signing
   * committee members are directly included in the attestations.
   * @param _length - The number of addresses to return, should match the number of committee members
   * @return The addresses of the committee members.
   */
  function reconstructCommitteeFromSigners(
    CommitteeAttestations memory _attestations,
    address[] memory _signers,
    uint256 _length
  ) internal pure returns (address[] memory) {
    uint256 bitmapBytes = (_length + 7) / 8; // Round up to nearest byte
    require(
      bitmapBytes == _attestations.signatureIndices.length,
      Errors.AttestationLib__SignatureIndicesSizeMismatch(bitmapBytes, _attestations.signatureIndices.length)
    );

    // To get a ref that we can easily use with the assembly down below.
    bytes memory signaturesOrAddresses = _attestations.signaturesOrAddresses;
    address[] memory addresses = new address[](_length);

    uint256 signersIndex;
    uint256 dataPtr;
    uint256 currentByte;
    uint256 bitMask;

    assembly {
      // Skip length
      dataPtr := add(signaturesOrAddresses, 0x20)
    }
    uint256 offset = dataPtr;

    for (uint256 i = 0; i < _length; ++i) {
      // Load new byte every 8 iterations
      if (i % 8 == 0) {
        uint256 byteIndex = i / 8;
        currentByte = uint8(_attestations.signatureIndices[byteIndex]);
        bitMask = 128; // 0b10000000
      }

      bool isSignatureFlag = (currentByte & bitMask) != 0;
      bitMask >>= 1;

      if (isSignatureFlag) {
        dataPtr += SIGNATURE_LENGTH;
        addresses[i] = _signers[signersIndex];
        signersIndex++;
      } else {
        address addr;
        assembly {
          addr := shr(96, mload(dataPtr))
          dataPtr := add(dataPtr, 20)
        }
        addresses[i] = addr;
      }
    }

    // Ensure that the size of data provided actually matches what we expect
    uint256 sizeOfSignaturesAndAddresses =
      (signersIndex * SIGNATURE_LENGTH) + ((_length - signersIndex) * ADDRESS_LENGTH);
    require(
      sizeOfSignaturesAndAddresses == _attestations.signaturesOrAddresses.length,
      Errors.AttestationLib__SignaturesOrAddressesSizeMismatch(
        sizeOfSignaturesAndAddresses, _attestations.signaturesOrAddresses.length
      )
    );
    require(signersIndex == _signers.length, Errors.AttestationLib__SignersSizeMismatch(signersIndex, _signers.length));

    // Ensure that the reads were within the boundaries of the data, and that we have read all the data.
    // This check is an extra precaution. There are two cases, we we would end up with an invalid
    // read, and both should be covered by the above checks.
    // 1. If trying to read beyond the expected data, the bitmap must have more ones than signatures,
    // but this will make the the `sizeOfSignaturesAndAddresses` larger than passed data.
    // 2. If trying to read less than expected data, the bitmap must have fewer ones than signatures,
    // but this will make the the `sizeOfSignaturesAndAddresses` smaller than passed data.
    uint256 upperLimit = offset + _attestations.signaturesOrAddresses.length;
    require(dataPtr == upperLimit, Errors.AttestationLib__InvalidDataSize(dataPtr - offset, upperLimit - offset));

    return addresses;
  }

  function getAttestationsAndSignersDigest(CommitteeAttestations memory _attestations, address[] memory _signers)
    internal
    pure
    returns (bytes32)
  {
    return keccak256(abi.encode(SignatureDomainSeparator.attestationsAndSigners, _attestations, _signers));
  }
}


// File: lib/l1-contracts/src/core/reward-boost/RewardBooster.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {IValidatorSelection} from "@aztec/core/interfaces/IValidatorSelection.sol";
import {Errors} from "@aztec/core/libraries/Errors.sol";
import {CompressedEpoch, CompressedTimeMath} from "@aztec/shared/libraries/CompressedTimeMath.sol";
import {Epoch} from "@aztec/shared/libraries/TimeMath.sol";
import {Math} from "@oz/utils/math/Math.sol";
import {SafeCast} from "@oz/utils/math/SafeCast.sol";

struct RewardBoostConfig {
  uint32 increment;
  uint32 maxScore;
  uint32 a; // a
  uint32 minimum; // m
  uint32 k; // k
}

struct ActivityScore {
  Epoch time;
  uint32 value;
}

struct CompressedActivityScore {
  CompressedEpoch time;
  uint32 value;
}

interface IBoosterCore {
  function updateAndGetShares(address _prover) external returns (uint256);
  function getSharesFor(address _prover) external view returns (uint256);
}

interface IBooster is IBoosterCore {
  function getConfig() external view returns (RewardBoostConfig memory);
  function getActivityScore(address _prover) external view returns (ActivityScore memory);
}

/**
 * @title RewardBooster
 *
 * @notice  Abstracts the accounting related to rewards boosting from the POV of the rollup.
 */
contract RewardBooster is IBooster {
  using SafeCast for uint256;
  using CompressedTimeMath for Epoch;
  using CompressedTimeMath for CompressedEpoch;

  IValidatorSelection public immutable ROLLUP;
  uint256 private immutable CONFIG_INCREMENT;
  uint256 private immutable CONFIG_MAX_SCORE;
  uint256 private immutable CONFIG_A;
  uint256 private immutable CONFIG_MINIMUM;
  uint256 private immutable CONFIG_K;

  mapping(address prover => CompressedActivityScore) internal activityScores;

  modifier onlyRollup() {
    require(msg.sender == address(ROLLUP), Errors.RewardBooster__OnlyRollup(msg.sender));
    _;
  }

  constructor(IValidatorSelection _rollup, RewardBoostConfig memory _config) {
    ROLLUP = _rollup;

    CONFIG_INCREMENT = _config.increment;
    CONFIG_MAX_SCORE = _config.maxScore;
    CONFIG_A = _config.a;
    CONFIG_MINIMUM = _config.minimum;
    CONFIG_K = _config.k;
  }

  function updateAndGetShares(address _prover) external override(IBoosterCore) onlyRollup returns (uint256) {
    Epoch currentEpoch = ROLLUP.getCurrentEpoch();

    CompressedActivityScore storage store = activityScores[_prover];
    ActivityScore memory curr = _activityScoreAt(store, currentEpoch);

    // If the score was already marked active in this epoch, ignore the addition.
    if (curr.time != store.time.decompress()) {
      store.value = Math.min(curr.value + CONFIG_INCREMENT, CONFIG_MAX_SCORE).toUint32();
      store.time = curr.time.compress();
    }

    return _toShares(store.value);
  }

  function getConfig() external view override(IBooster) returns (RewardBoostConfig memory) {
    return RewardBoostConfig({
      increment: CONFIG_INCREMENT.toUint32(),
      maxScore: CONFIG_MAX_SCORE.toUint32(),
      a: CONFIG_A.toUint32(),
      minimum: CONFIG_MINIMUM.toUint32(),
      k: CONFIG_K.toUint32()
    });
  }

  function getSharesFor(address _prover) external view override(IBoosterCore) returns (uint256) {
    return _toShares(getActivityScore(_prover).value);
  }

  function getActivityScore(address _prover) public view override(IBooster) returns (ActivityScore memory) {
    return _activityScoreAt(activityScores[_prover], ROLLUP.getCurrentEpoch());
  }

  function _activityScoreAt(CompressedActivityScore storage _score, Epoch _epoch)
    internal
    view
    returns (ActivityScore memory)
  {
    uint256 decrease = (Epoch.unwrap(_epoch) - Epoch.unwrap(_score.time.decompress())) * 1e5;
    return
      ActivityScore({value: decrease > uint256(_score.value) ? 0 : _score.value - decrease.toUint32(), time: _epoch});
  }

  function _toShares(uint256 _value) internal view returns (uint256) {
    if (_value >= CONFIG_MAX_SCORE) {
      return CONFIG_K;
    }
    uint256 t = (CONFIG_MAX_SCORE - _value);
    uint256 rhs = CONFIG_A * t * t / 1e10;

    // Sub would move us below 0
    if (CONFIG_K < rhs) {
      return CONFIG_MINIMUM;
    }

    return Math.max(CONFIG_K - rhs, CONFIG_MINIMUM);
  }
}


// File: lib/l1-contracts/src/governance/interfaces/IRegistry.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27;

import {IRewardDistributor} from "@aztec/governance/interfaces/IRewardDistributor.sol";

interface IHaveVersion {
  function getVersion() external view returns (uint256);
}

interface IRegistry {
  event CanonicalRollupUpdated(address indexed instance, uint256 indexed version);
  event RewardDistributorUpdated(address indexed rewardDistributor);

  function addRollup(IHaveVersion _rollup) external;
  function updateRewardDistributor(address _rewardDistributor) external;

  // docs:start:registry_get_canonical_rollup
  function getCanonicalRollup() external view returns (IHaveVersion);
  // docs:end:registry_get_canonical_rollup

  // docs:start:registry_get_rollup
  function getRollup(uint256 _chainId) external view returns (IHaveVersion);
  // docs:end:registry_get_rollup

  // docs:start:registry_number_of_versions
  function numberOfVersions() external view returns (uint256);
  // docs:end:registry_number_of_versions

  function getGovernance() external view returns (address);

  function getRewardDistributor() external view returns (IRewardDistributor);

  function getVersion(uint256 _index) external view returns (uint256);
}


// File: lib/l1-contracts/src/shared/libraries/TimeMath.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

type Timestamp is uint256;

type Slot is uint256;

type Epoch is uint256;

function addTimestamp(Timestamp _a, Timestamp _b) pure returns (Timestamp) {
  return Timestamp.wrap(Timestamp.unwrap(_a) + Timestamp.unwrap(_b));
}

function subTimestamp(Timestamp _a, Timestamp _b) pure returns (Timestamp) {
  return Timestamp.wrap(Timestamp.unwrap(_a) - Timestamp.unwrap(_b));
}

function ltTimestamp(Timestamp _a, Timestamp _b) pure returns (bool) {
  return Timestamp.unwrap(_a) < Timestamp.unwrap(_b);
}

function lteTimestamp(Timestamp _a, Timestamp _b) pure returns (bool) {
  return Timestamp.unwrap(_a) <= Timestamp.unwrap(_b);
}

function gtTimestamp(Timestamp _a, Timestamp _b) pure returns (bool) {
  return Timestamp.unwrap(_a) > Timestamp.unwrap(_b);
}

function gteTimestamp(Timestamp _a, Timestamp _b) pure returns (bool) {
  return Timestamp.unwrap(_a) >= Timestamp.unwrap(_b);
}

function neqTimestamp(Timestamp _a, Timestamp _b) pure returns (bool) {
  return Timestamp.unwrap(_a) != Timestamp.unwrap(_b);
}

function eqTimestamp(Timestamp _a, Timestamp _b) pure returns (bool) {
  return Timestamp.unwrap(_a) == Timestamp.unwrap(_b);
}

// Slot

function addSlot(Slot _a, Slot _b) pure returns (Slot) {
  return Slot.wrap(Slot.unwrap(_a) + Slot.unwrap(_b));
}

function subSlot(Slot _a, Slot _b) pure returns (Slot) {
  return Slot.wrap(Slot.unwrap(_a) - Slot.unwrap(_b));
}

function eqSlot(Slot _a, Slot _b) pure returns (bool) {
  return Slot.unwrap(_a) == Slot.unwrap(_b);
}

function neqSlot(Slot _a, Slot _b) pure returns (bool) {
  return Slot.unwrap(_a) != Slot.unwrap(_b);
}

function ltSlot(Slot _a, Slot _b) pure returns (bool) {
  return Slot.unwrap(_a) < Slot.unwrap(_b);
}

function lteSlot(Slot _a, Slot _b) pure returns (bool) {
  return Slot.unwrap(_a) <= Slot.unwrap(_b);
}

function gtSlot(Slot _a, Slot _b) pure returns (bool) {
  return Slot.unwrap(_a) > Slot.unwrap(_b);
}

function gteSlot(Slot _a, Slot _b) pure returns (bool) {
  return Slot.unwrap(_a) >= Slot.unwrap(_b);
}

// Epoch

function eqEpoch(Epoch _a, Epoch _b) pure returns (bool) {
  return Epoch.unwrap(_a) == Epoch.unwrap(_b);
}

function neqEpoch(Epoch _a, Epoch _b) pure returns (bool) {
  return Epoch.unwrap(_a) != Epoch.unwrap(_b);
}

function subEpoch(Epoch _a, Epoch _b) pure returns (Epoch) {
  return Epoch.wrap(Epoch.unwrap(_a) - Epoch.unwrap(_b));
}

function addEpoch(Epoch _a, Epoch _b) pure returns (Epoch) {
  return Epoch.wrap(Epoch.unwrap(_a) + Epoch.unwrap(_b));
}

function gteEpoch(Epoch _a, Epoch _b) pure returns (bool) {
  return Epoch.unwrap(_a) >= Epoch.unwrap(_b);
}

function gtEpoch(Epoch _a, Epoch _b) pure returns (bool) {
  return Epoch.unwrap(_a) > Epoch.unwrap(_b);
}

function lteEpoch(Epoch _a, Epoch _b) pure returns (bool) {
  return Epoch.unwrap(_a) <= Epoch.unwrap(_b);
}

function ltEpoch(Epoch _a, Epoch _b) pure returns (bool) {
  return Epoch.unwrap(_a) < Epoch.unwrap(_b);
}

using {
  addTimestamp as +,
  subTimestamp as -,
  ltTimestamp as <,
  gtTimestamp as >,
  lteTimestamp as <=,
  gteTimestamp as >=,
  neqTimestamp as !=,
  eqTimestamp as ==
} for Timestamp global;

using {
  addEpoch as +,
  subEpoch as -,
  eqEpoch as ==,
  neqEpoch as !=,
  gteEpoch as >=,
  gtEpoch as >,
  lteEpoch as <=,
  ltEpoch as <
} for Epoch global;

using {
  eqSlot as ==,
  neqSlot as !=,
  gteSlot as >=,
  gtSlot as >,
  lteSlot as <=,
  ltSlot as <,
  addSlot as +,
  subSlot as -
} for Slot global;


// File: lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/IERC20.sol)

pragma solidity ^0.8.20;

/**
 * @dev Interface of the ERC-20 standard as defined in the ERC.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}


// File: lib/l1-contracts/src/shared/libraries/BN254Lib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

struct G1Point {
  uint256 x;
  uint256 y;
}

struct G2Point {
  uint256 x0;
  uint256 x1;
  uint256 y0;
  uint256 y1;
}

/**
 * Credit:
 * Primary inspiration from https://hackmd.io/7B4nfNShSY2Cjln-9ViQrA, which points out the
 * optimization of linking/using a G1 and G2 key and provides an implementation for
 * the hashToPoint and sqrt functions.
 */

/**
 * Library for registering public keys and computing BLS signatures over the BN254 curve.
 * The BN254 curve has been chosen over the BLS12-381 curve for gas efficiency, and
 * because the Aztec rollup's security is already reliant on BN254.
 */
library BN254Lib {
  /**
   * We use uint256[2] for G1 points and uint256[4] for G2 points.
   * For G1 points, the expected order is (x, y).
   * For G2 points, the expected order is (x_imaginary, x_real, y_imaginary, y_real)
   * Using structs would be more readable, but it would be more expensive to use them, particularly
   * when aggregating the public keys, since we need to convert to uint256[2] and uint256[4] anyway.
   */

  // See bn254_registration.test.ts and BLSKey.t.sol for tests which validate these constants.
  uint256 public constant BASE_FIELD_ORDER =
    21_888_242_871_839_275_222_246_405_745_257_275_088_696_311_157_297_823_662_689_037_894_645_226_208_583;

  uint256 public constant GROUP_ORDER =
    21_888_242_871_839_275_222_246_405_745_257_275_088_548_364_400_416_034_343_698_204_186_575_808_495_617;

  bytes32 public constant STAKING_DOMAIN_SEPARATOR = bytes32("AZTEC_BLS_POP_BN254_V1");

  error AddPointFail();
  error MulPointFail();
  error GammaZero();
  error SqrtFail();
  error PairingFail();
  error NoPointFound();
  error InfinityNotAllowed();

  /**
   * @notice Prove possession of a secret for a point in G1 and G2.
   *
   * Ultimately, we want to check:
   * - That the caller knows the secret key of pk2 (to prevent rogue-key attacks)
   * - That pk1 and pk2 have the same secret key (as an optimization)
   *
   * Registering two public keys is an optimization: It means we can do G1-only operations
   * at the time of verifying a signature, which is much cheaper than G2 operations.
   *
   * In this function, we check:
   * e(signature + gamma * pk1, -G2) * e(hashToPoint(pk1) + gamma * G1, pk2) == 1
   *
   * Which is effectively a check that:
   * e(signature, G2) == e(hashToPoint(pk1), pk2) // a BLS signature over msg = pk1, to prove knowledge of the sk.
   * e(pk1, G2) == e(G1, pk2) // a demonstration that pk1 and pk2 have the same sk.
   *
   * @param pk1 The G1 point of the BLS public key (x, y coordinates)
   * @param pk2 The G2 point of the BLS public key (x_1, x_0, y_1, y_0 coordinates)
   * @param signature The G1 point that acts as a proof of possession of the private keys corresponding to pk1 and pk2
   */
  function proofOfPossession(G1Point memory pk1, G2Point memory pk2, G1Point memory signature)
    internal
    view
    returns (bool)
  {
    // Ensure that provided points are not infinity
    require(!isZero(pk1), InfinityNotAllowed());
    require(!isZero(pk2), InfinityNotAllowed());
    require(!isZero(signature), InfinityNotAllowed());

    // Compute the point "digest" of the pk1 that sigma is a signature over
    G1Point memory pk1DigestPoint = g1ToDigestPoint(pk1);

    // Random challenge:
    // gamma = keccak(pk1, pk2, signature) mod |Fr|
    uint256 gamma = gammaOf(pk1, pk2, signature);
    require(gamma != 0, GammaZero());

    // Build G1 L = signature + gamma * pk1
    G1Point memory left = g1Add(signature, g1Mul(pk1, gamma));

    // Build G1 R = pk1DigestPoint + gamma * G1
    G1Point memory right = g1Add(pk1DigestPoint, g1Mul(g1Generator(), gamma));

    // Pairing: e(L, -G2) * e(R, pk2) == 1
    return bn254Pairing(left, g2NegatedGenerator(), right, pk2);
  }

  /// @notice Convert a G1 point (public key) to the digest point that must be signed to prove possession.
  /// @dev exposed as public to allow clients not to have implemented the hashToPoint function.
  function g1ToDigestPoint(G1Point memory pk1) internal view returns (G1Point memory) {
    bytes memory pk1Bytes = abi.encodePacked(pk1.x, pk1.y);
    return hashToPoint(STAKING_DOMAIN_SEPARATOR, pk1Bytes);
  }

  /// @dev Add two points on BN254 G1 (affine coords).
  ///      Reverts if the inputs are not on‐curve.
  function g1Add(G1Point memory p1, G1Point memory p2) internal view returns (G1Point memory output) {
    uint256[4] memory input;
    input[0] = p1.x;
    input[1] = p1.y;
    input[2] = p2.x;
    input[3] = p2.y;

    bool success;
    assembly {
      // call(gas, to, value, in, insize, out, outsize)
      // STATICCALL is 40 gas vs 700 gas for CALL
      success :=
        staticcall(
          sub(gas(), 2000),
          0x06, // precompile address
          input,
          0x80, // input size = 4 × 32 bytes
          output,
          0x40 // output size = 2 × 32 bytes
        )
    }

    if (!success) revert AddPointFail();
    return output;
  }

  /// @dev Multiply a point by a scalar (little‑endian 256‑bit integer).
  ///      Reverts if the point is not on‐curve or the scalar ≥ p.
  function g1Mul(G1Point memory p, uint256 s) internal view returns (G1Point memory output) {
    uint256[3] memory input;
    input[0] = p.x;
    input[1] = p.y;
    input[2] = s;

    bool success;
    assembly {
      success :=
        staticcall(
          sub(gas(), 2000),
          0x07, // precompile address
          input,
          0x60, // input size = 3 × 32 bytes
          output,
          0x40 // output size = 2 × 32 bytes
        )
    }
    if (!success) revert MulPointFail();
    return output;
  }

  function bn254Pairing(G1Point memory g1a, G2Point memory g2a, G1Point memory g1b, G2Point memory g2b)
    internal
    view
    returns (bool)
  {
    uint256[12] memory input;

    input[0] = g1a.x;
    input[1] = g1a.y;
    input[2] = g2a.x1;
    input[3] = g2a.x0;
    input[4] = g2a.y1;
    input[5] = g2a.y0;

    input[6] = g1b.x;
    input[7] = g1b.y;
    input[8] = g2b.x1;
    input[9] = g2b.x0;
    input[10] = g2b.y1;
    input[11] = g2b.y0;

    uint256[1] memory result;
    bool didCallSucceed;
    assembly {
      didCallSucceed :=
        staticcall(
          sub(gas(), 2000),
          8,
          input,
          0x180, // input size = 12 * 32 bytes
          result,
          0x20 // output size = 32 bytes
        )
    }
    require(didCallSucceed, PairingFail());
    return result[0] == 1;
  }

  // The hash to point is based on the "mapToPoint" function in https://www.iacr.org/archive/asiacrypt2001/22480516.pdf
  function hashToPoint(bytes32 domain, bytes memory message) internal view returns (G1Point memory output) {
    bool found = false;
    uint256 attempts = 0;
    while (true) {
      uint256 x = uint256(keccak256(abi.encode(domain, message, attempts)));
      attempts++;

      if (x >= BASE_FIELD_ORDER) {
        continue;
      }

      uint256 y = mulmod(x, x, BASE_FIELD_ORDER);
      y = mulmod(y, x, BASE_FIELD_ORDER);
      y = addmod(y, 3, BASE_FIELD_ORDER);
      (y, found) = sqrt(y);
      if (found) {
        uint256 y0 = y;
        uint256 y1 = BASE_FIELD_ORDER - y;

        // Ensure that y1 > y0, flip em if necessary
        if (y0 > y1) {
          (y0, y1) = (y1, y0);
        }

        uint256 b = uint256(keccak256(abi.encode(domain, message, type(uint256).max)));
        if (b & 1 == 0) {
          output = G1Point({x: x, y: y0});
        } else {
          output = G1Point({x: x, y: y1});
        }

        break;
      }
    }
    require(found, NoPointFound());
    return output;
  }

  function sqrt(uint256 xx) internal view returns (uint256 x, bool hasRoot) {
    bool callSuccess;
    assembly {
      let freeMem := mload(0x40)
      mstore(freeMem, 0x20)
      mstore(add(freeMem, 0x20), 0x20)
      mstore(add(freeMem, 0x40), 0x20)
      mstore(add(freeMem, 0x60), xx)
      // (N + 1) / 4 = 0xc19139cb84c680a6e14116da060561765e05aa45a1c72a34f082305b61f3f52
      mstore(add(freeMem, 0x80), 0xc19139cb84c680a6e14116da060561765e05aa45a1c72a34f082305b61f3f52)
      // N = BASE_FIELD_ORDER
      mstore(add(freeMem, 0xA0), BASE_FIELD_ORDER)
      callSuccess := staticcall(sub(gas(), 2000), 5, freeMem, 0xC0, freeMem, 0x20)
      x := mload(freeMem)
      hasRoot := eq(xx, mulmod(x, x, BASE_FIELD_ORDER))
    }
    require(callSuccess, SqrtFail());
  }

  /// @notice γ = keccak(PK1, PK2, σ_init) mod Fr
  function gammaOf(G1Point memory pk1, G2Point memory pk2, G1Point memory sigmaInit) internal pure returns (uint256) {
    return uint256(keccak256(abi.encode(pk1.x, pk1.y, pk2.x0, pk2.x1, pk2.y0, pk2.y1, sigmaInit.x, sigmaInit.y)))
      % GROUP_ORDER;
  }

  function g1Negate(G1Point memory p) internal pure returns (G1Point memory) {
    if (p.x == 0 && p.y == 0) {
      // Point at infinity remains unchanged
      return p;
    }

    // For a point (x, y), its negation is (x, -y mod p)
    // Since we're working in the field Fp, -y mod p = p - y
    return G1Point({x: p.x, y: BASE_FIELD_ORDER - p.y});
  }

  function g1Zero() internal pure returns (G1Point memory) {
    return G1Point({x: 0, y: 0});
  }

  function isZero(G1Point memory p) internal pure returns (bool) {
    return p.x == 0 && p.y == 0;
  }

  function g1Generator() internal pure returns (G1Point memory) {
    return G1Point({x: 1, y: 2});
  }

  function g2Zero() internal pure returns (G2Point memory) {
    return G2Point({x0: 0, x1: 0, y0: 0, y1: 0});
  }

  function isZero(G2Point memory p) internal pure returns (bool) {
    return p.x0 == 0 && p.x1 == 0 && p.y0 == 0 && p.y1 == 0;
  }

  function g2NegatedGenerator() internal pure returns (G2Point memory) {
    return G2Point({
      x0: 10_857_046_999_023_057_135_944_570_762_232_829_481_370_756_359_578_518_086_990_519_993_285_655_852_781,
      x1: 11_559_732_032_986_387_107_991_004_021_392_285_783_925_812_861_821_192_530_917_403_151_452_391_805_634,
      y0: 13_392_588_948_715_843_804_641_432_497_768_002_650_278_120_570_034_223_513_918_757_245_338_268_106_653,
      y1: 17_805_874_995_975_841_540_914_202_342_111_839_520_379_459_829_704_422_454_583_296_818_431_106_115_052
    });
  }
}


// File: lib/l1-contracts/src/governance/interfaces/IEmpire.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
// solhint-disable imports-order
pragma solidity >=0.8.27;

import {Slot} from "@aztec/shared/libraries/TimeMath.sol";
import {Signature} from "@aztec/shared/libraries/SignatureLib.sol";
import {IPayload} from "@aztec/governance/interfaces/IPayload.sol";

interface IEmperor {
  // Not view because it might rely on transient storage.
  // Calls are essentially trusted
  function getCurrentProposer() external returns (address);

  function getCurrentSlot() external view returns (Slot);
}

interface IEmpire {
  event SignalCast(IPayload indexed payload, uint256 indexed round, address indexed signaler);
  event PayloadSubmittable(IPayload indexed payload, uint256 indexed round);
  event PayloadSubmitted(IPayload indexed payload, uint256 indexed round);

  function signal(IPayload _payload) external returns (bool);
  function signalWithSig(IPayload _payload, Signature memory _sig) external returns (bool);

  function submitRoundWinner(uint256 _roundNumber) external returns (bool);
  function signalCount(address _instance, uint256 _round, IPayload _payload) external view returns (uint256);
  function computeRound(Slot _slot) external view returns (uint256);
  function getInstance() external view returns (address);
}


// File: lib/openzeppelin-contracts/contracts/utils/structs/Checkpoints.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.3.0) (utils/structs/Checkpoints.sol)
// This file was procedurally generated from scripts/generate/templates/Checkpoints.js.

pragma solidity ^0.8.20;

import {Math} from "../math/Math.sol";

/**
 * @dev This library defines the `Trace*` struct, for checkpointing values as they change at different points in
 * time, and later looking up past values by block number. See {Votes} as an example.
 *
 * To create a history of checkpoints define a variable type `Checkpoints.Trace*` in your contract, and store a new
 * checkpoint for the current transaction block using the {push} function.
 */
library Checkpoints {
    /**
     * @dev A value was attempted to be inserted on a past checkpoint.
     */
    error CheckpointUnorderedInsertion();

    struct Trace224 {
        Checkpoint224[] _checkpoints;
    }

    struct Checkpoint224 {
        uint32 _key;
        uint224 _value;
    }

    /**
     * @dev Pushes a (`key`, `value`) pair into a Trace224 so that it is stored as the checkpoint.
     *
     * Returns previous value and new value.
     *
     * IMPORTANT: Never accept `key` as a user input, since an arbitrary `type(uint32).max` key set will disable the
     * library.
     */
    function push(
        Trace224 storage self,
        uint32 key,
        uint224 value
    ) internal returns (uint224 oldValue, uint224 newValue) {
        return _insert(self._checkpoints, key, value);
    }

    /**
     * @dev Returns the value in the first (oldest) checkpoint with key greater or equal than the search key, or zero if
     * there is none.
     */
    function lowerLookup(Trace224 storage self, uint32 key) internal view returns (uint224) {
        uint256 len = self._checkpoints.length;
        uint256 pos = _lowerBinaryLookup(self._checkpoints, key, 0, len);
        return pos == len ? 0 : _unsafeAccess(self._checkpoints, pos)._value;
    }

    /**
     * @dev Returns the value in the last (most recent) checkpoint with key lower or equal than the search key, or zero
     * if there is none.
     */
    function upperLookup(Trace224 storage self, uint32 key) internal view returns (uint224) {
        uint256 len = self._checkpoints.length;
        uint256 pos = _upperBinaryLookup(self._checkpoints, key, 0, len);
        return pos == 0 ? 0 : _unsafeAccess(self._checkpoints, pos - 1)._value;
    }

    /**
     * @dev Returns the value in the last (most recent) checkpoint with key lower or equal than the search key, or zero
     * if there is none.
     *
     * NOTE: This is a variant of {upperLookup} that is optimised to find "recent" checkpoint (checkpoints with high
     * keys).
     */
    function upperLookupRecent(Trace224 storage self, uint32 key) internal view returns (uint224) {
        uint256 len = self._checkpoints.length;

        uint256 low = 0;
        uint256 high = len;

        if (len > 5) {
            uint256 mid = len - Math.sqrt(len);
            if (key < _unsafeAccess(self._checkpoints, mid)._key) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        uint256 pos = _upperBinaryLookup(self._checkpoints, key, low, high);

        return pos == 0 ? 0 : _unsafeAccess(self._checkpoints, pos - 1)._value;
    }

    /**
     * @dev Returns the value in the most recent checkpoint, or zero if there are no checkpoints.
     */
    function latest(Trace224 storage self) internal view returns (uint224) {
        uint256 pos = self._checkpoints.length;
        return pos == 0 ? 0 : _unsafeAccess(self._checkpoints, pos - 1)._value;
    }

    /**
     * @dev Returns whether there is a checkpoint in the structure (i.e. it is not empty), and if so the key and value
     * in the most recent checkpoint.
     */
    function latestCheckpoint(Trace224 storage self) internal view returns (bool exists, uint32 _key, uint224 _value) {
        uint256 pos = self._checkpoints.length;
        if (pos == 0) {
            return (false, 0, 0);
        } else {
            Checkpoint224 storage ckpt = _unsafeAccess(self._checkpoints, pos - 1);
            return (true, ckpt._key, ckpt._value);
        }
    }

    /**
     * @dev Returns the number of checkpoints.
     */
    function length(Trace224 storage self) internal view returns (uint256) {
        return self._checkpoints.length;
    }

    /**
     * @dev Returns checkpoint at given position.
     */
    function at(Trace224 storage self, uint32 pos) internal view returns (Checkpoint224 memory) {
        return self._checkpoints[pos];
    }

    /**
     * @dev Pushes a (`key`, `value`) pair into an ordered list of checkpoints, either by inserting a new checkpoint,
     * or by updating the last one.
     */
    function _insert(
        Checkpoint224[] storage self,
        uint32 key,
        uint224 value
    ) private returns (uint224 oldValue, uint224 newValue) {
        uint256 pos = self.length;

        if (pos > 0) {
            Checkpoint224 storage last = _unsafeAccess(self, pos - 1);
            uint32 lastKey = last._key;
            uint224 lastValue = last._value;

            // Checkpoint keys must be non-decreasing.
            if (lastKey > key) {
                revert CheckpointUnorderedInsertion();
            }

            // Update or push new checkpoint
            if (lastKey == key) {
                last._value = value;
            } else {
                self.push(Checkpoint224({_key: key, _value: value}));
            }
            return (lastValue, value);
        } else {
            self.push(Checkpoint224({_key: key, _value: value}));
            return (0, value);
        }
    }

    /**
     * @dev Return the index of the first (oldest) checkpoint with key strictly bigger than the search key, or `high`
     * if there is none. `low` and `high` define a section where to do the search, with inclusive `low` and exclusive
     * `high`.
     *
     * WARNING: `high` should not be greater than the array's length.
     */
    function _upperBinaryLookup(
        Checkpoint224[] storage self,
        uint32 key,
        uint256 low,
        uint256 high
    ) private view returns (uint256) {
        while (low < high) {
            uint256 mid = Math.average(low, high);
            if (_unsafeAccess(self, mid)._key > key) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        return high;
    }

    /**
     * @dev Return the index of the first (oldest) checkpoint with key greater or equal than the search key, or `high`
     * if there is none. `low` and `high` define a section where to do the search, with inclusive `low` and exclusive
     * `high`.
     *
     * WARNING: `high` should not be greater than the array's length.
     */
    function _lowerBinaryLookup(
        Checkpoint224[] storage self,
        uint32 key,
        uint256 low,
        uint256 high
    ) private view returns (uint256) {
        while (low < high) {
            uint256 mid = Math.average(low, high);
            if (_unsafeAccess(self, mid)._key < key) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return high;
    }

    /**
     * @dev Access an element of the array without performing bounds check. The position is assumed to be within bounds.
     */
    function _unsafeAccess(
        Checkpoint224[] storage self,
        uint256 pos
    ) private pure returns (Checkpoint224 storage result) {
        assembly {
            mstore(0, self.slot)
            result.slot := add(keccak256(0, 0x20), pos)
        }
    }

    struct Trace208 {
        Checkpoint208[] _checkpoints;
    }

    struct Checkpoint208 {
        uint48 _key;
        uint208 _value;
    }

    /**
     * @dev Pushes a (`key`, `value`) pair into a Trace208 so that it is stored as the checkpoint.
     *
     * Returns previous value and new value.
     *
     * IMPORTANT: Never accept `key` as a user input, since an arbitrary `type(uint48).max` key set will disable the
     * library.
     */
    function push(
        Trace208 storage self,
        uint48 key,
        uint208 value
    ) internal returns (uint208 oldValue, uint208 newValue) {
        return _insert(self._checkpoints, key, value);
    }

    /**
     * @dev Returns the value in the first (oldest) checkpoint with key greater or equal than the search key, or zero if
     * there is none.
     */
    function lowerLookup(Trace208 storage self, uint48 key) internal view returns (uint208) {
        uint256 len = self._checkpoints.length;
        uint256 pos = _lowerBinaryLookup(self._checkpoints, key, 0, len);
        return pos == len ? 0 : _unsafeAccess(self._checkpoints, pos)._value;
    }

    /**
     * @dev Returns the value in the last (most recent) checkpoint with key lower or equal than the search key, or zero
     * if there is none.
     */
    function upperLookup(Trace208 storage self, uint48 key) internal view returns (uint208) {
        uint256 len = self._checkpoints.length;
        uint256 pos = _upperBinaryLookup(self._checkpoints, key, 0, len);
        return pos == 0 ? 0 : _unsafeAccess(self._checkpoints, pos - 1)._value;
    }

    /**
     * @dev Returns the value in the last (most recent) checkpoint with key lower or equal than the search key, or zero
     * if there is none.
     *
     * NOTE: This is a variant of {upperLookup} that is optimised to find "recent" checkpoint (checkpoints with high
     * keys).
     */
    function upperLookupRecent(Trace208 storage self, uint48 key) internal view returns (uint208) {
        uint256 len = self._checkpoints.length;

        uint256 low = 0;
        uint256 high = len;

        if (len > 5) {
            uint256 mid = len - Math.sqrt(len);
            if (key < _unsafeAccess(self._checkpoints, mid)._key) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        uint256 pos = _upperBinaryLookup(self._checkpoints, key, low, high);

        return pos == 0 ? 0 : _unsafeAccess(self._checkpoints, pos - 1)._value;
    }

    /**
     * @dev Returns the value in the most recent checkpoint, or zero if there are no checkpoints.
     */
    function latest(Trace208 storage self) internal view returns (uint208) {
        uint256 pos = self._checkpoints.length;
        return pos == 0 ? 0 : _unsafeAccess(self._checkpoints, pos - 1)._value;
    }

    /**
     * @dev Returns whether there is a checkpoint in the structure (i.e. it is not empty), and if so the key and value
     * in the most recent checkpoint.
     */
    function latestCheckpoint(Trace208 storage self) internal view returns (bool exists, uint48 _key, uint208 _value) {
        uint256 pos = self._checkpoints.length;
        if (pos == 0) {
            return (false, 0, 0);
        } else {
            Checkpoint208 storage ckpt = _unsafeAccess(self._checkpoints, pos - 1);
            return (true, ckpt._key, ckpt._value);
        }
    }

    /**
     * @dev Returns the number of checkpoints.
     */
    function length(Trace208 storage self) internal view returns (uint256) {
        return self._checkpoints.length;
    }

    /**
     * @dev Returns checkpoint at given position.
     */
    function at(Trace208 storage self, uint32 pos) internal view returns (Checkpoint208 memory) {
        return self._checkpoints[pos];
    }

    /**
     * @dev Pushes a (`key`, `value`) pair into an ordered list of checkpoints, either by inserting a new checkpoint,
     * or by updating the last one.
     */
    function _insert(
        Checkpoint208[] storage self,
        uint48 key,
        uint208 value
    ) private returns (uint208 oldValue, uint208 newValue) {
        uint256 pos = self.length;

        if (pos > 0) {
            Checkpoint208 storage last = _unsafeAccess(self, pos - 1);
            uint48 lastKey = last._key;
            uint208 lastValue = last._value;

            // Checkpoint keys must be non-decreasing.
            if (lastKey > key) {
                revert CheckpointUnorderedInsertion();
            }

            // Update or push new checkpoint
            if (lastKey == key) {
                last._value = value;
            } else {
                self.push(Checkpoint208({_key: key, _value: value}));
            }
            return (lastValue, value);
        } else {
            self.push(Checkpoint208({_key: key, _value: value}));
            return (0, value);
        }
    }

    /**
     * @dev Return the index of the first (oldest) checkpoint with key strictly bigger than the search key, or `high`
     * if there is none. `low` and `high` define a section where to do the search, with inclusive `low` and exclusive
     * `high`.
     *
     * WARNING: `high` should not be greater than the array's length.
     */
    function _upperBinaryLookup(
        Checkpoint208[] storage self,
        uint48 key,
        uint256 low,
        uint256 high
    ) private view returns (uint256) {
        while (low < high) {
            uint256 mid = Math.average(low, high);
            if (_unsafeAccess(self, mid)._key > key) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        return high;
    }

    /**
     * @dev Return the index of the first (oldest) checkpoint with key greater or equal than the search key, or `high`
     * if there is none. `low` and `high` define a section where to do the search, with inclusive `low` and exclusive
     * `high`.
     *
     * WARNING: `high` should not be greater than the array's length.
     */
    function _lowerBinaryLookup(
        Checkpoint208[] storage self,
        uint48 key,
        uint256 low,
        uint256 high
    ) private view returns (uint256) {
        while (low < high) {
            uint256 mid = Math.average(low, high);
            if (_unsafeAccess(self, mid)._key < key) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return high;
    }

    /**
     * @dev Access an element of the array without performing bounds check. The position is assumed to be within bounds.
     */
    function _unsafeAccess(
        Checkpoint208[] storage self,
        uint256 pos
    ) private pure returns (Checkpoint208 storage result) {
        assembly {
            mstore(0, self.slot)
            result.slot := add(keccak256(0, 0x20), pos)
        }
    }

    struct Trace160 {
        Checkpoint160[] _checkpoints;
    }

    struct Checkpoint160 {
        uint96 _key;
        uint160 _value;
    }

    /**
     * @dev Pushes a (`key`, `value`) pair into a Trace160 so that it is stored as the checkpoint.
     *
     * Returns previous value and new value.
     *
     * IMPORTANT: Never accept `key` as a user input, since an arbitrary `type(uint96).max` key set will disable the
     * library.
     */
    function push(
        Trace160 storage self,
        uint96 key,
        uint160 value
    ) internal returns (uint160 oldValue, uint160 newValue) {
        return _insert(self._checkpoints, key, value);
    }

    /**
     * @dev Returns the value in the first (oldest) checkpoint with key greater or equal than the search key, or zero if
     * there is none.
     */
    function lowerLookup(Trace160 storage self, uint96 key) internal view returns (uint160) {
        uint256 len = self._checkpoints.length;
        uint256 pos = _lowerBinaryLookup(self._checkpoints, key, 0, len);
        return pos == len ? 0 : _unsafeAccess(self._checkpoints, pos)._value;
    }

    /**
     * @dev Returns the value in the last (most recent) checkpoint with key lower or equal than the search key, or zero
     * if there is none.
     */
    function upperLookup(Trace160 storage self, uint96 key) internal view returns (uint160) {
        uint256 len = self._checkpoints.length;
        uint256 pos = _upperBinaryLookup(self._checkpoints, key, 0, len);
        return pos == 0 ? 0 : _unsafeAccess(self._checkpoints, pos - 1)._value;
    }

    /**
     * @dev Returns the value in the last (most recent) checkpoint with key lower or equal than the search key, or zero
     * if there is none.
     *
     * NOTE: This is a variant of {upperLookup} that is optimised to find "recent" checkpoint (checkpoints with high
     * keys).
     */
    function upperLookupRecent(Trace160 storage self, uint96 key) internal view returns (uint160) {
        uint256 len = self._checkpoints.length;

        uint256 low = 0;
        uint256 high = len;

        if (len > 5) {
            uint256 mid = len - Math.sqrt(len);
            if (key < _unsafeAccess(self._checkpoints, mid)._key) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        uint256 pos = _upperBinaryLookup(self._checkpoints, key, low, high);

        return pos == 0 ? 0 : _unsafeAccess(self._checkpoints, pos - 1)._value;
    }

    /**
     * @dev Returns the value in the most recent checkpoint, or zero if there are no checkpoints.
     */
    function latest(Trace160 storage self) internal view returns (uint160) {
        uint256 pos = self._checkpoints.length;
        return pos == 0 ? 0 : _unsafeAccess(self._checkpoints, pos - 1)._value;
    }

    /**
     * @dev Returns whether there is a checkpoint in the structure (i.e. it is not empty), and if so the key and value
     * in the most recent checkpoint.
     */
    function latestCheckpoint(Trace160 storage self) internal view returns (bool exists, uint96 _key, uint160 _value) {
        uint256 pos = self._checkpoints.length;
        if (pos == 0) {
            return (false, 0, 0);
        } else {
            Checkpoint160 storage ckpt = _unsafeAccess(self._checkpoints, pos - 1);
            return (true, ckpt._key, ckpt._value);
        }
    }

    /**
     * @dev Returns the number of checkpoints.
     */
    function length(Trace160 storage self) internal view returns (uint256) {
        return self._checkpoints.length;
    }

    /**
     * @dev Returns checkpoint at given position.
     */
    function at(Trace160 storage self, uint32 pos) internal view returns (Checkpoint160 memory) {
        return self._checkpoints[pos];
    }

    /**
     * @dev Pushes a (`key`, `value`) pair into an ordered list of checkpoints, either by inserting a new checkpoint,
     * or by updating the last one.
     */
    function _insert(
        Checkpoint160[] storage self,
        uint96 key,
        uint160 value
    ) private returns (uint160 oldValue, uint160 newValue) {
        uint256 pos = self.length;

        if (pos > 0) {
            Checkpoint160 storage last = _unsafeAccess(self, pos - 1);
            uint96 lastKey = last._key;
            uint160 lastValue = last._value;

            // Checkpoint keys must be non-decreasing.
            if (lastKey > key) {
                revert CheckpointUnorderedInsertion();
            }

            // Update or push new checkpoint
            if (lastKey == key) {
                last._value = value;
            } else {
                self.push(Checkpoint160({_key: key, _value: value}));
            }
            return (lastValue, value);
        } else {
            self.push(Checkpoint160({_key: key, _value: value}));
            return (0, value);
        }
    }

    /**
     * @dev Return the index of the first (oldest) checkpoint with key strictly bigger than the search key, or `high`
     * if there is none. `low` and `high` define a section where to do the search, with inclusive `low` and exclusive
     * `high`.
     *
     * WARNING: `high` should not be greater than the array's length.
     */
    function _upperBinaryLookup(
        Checkpoint160[] storage self,
        uint96 key,
        uint256 low,
        uint256 high
    ) private view returns (uint256) {
        while (low < high) {
            uint256 mid = Math.average(low, high);
            if (_unsafeAccess(self, mid)._key > key) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        return high;
    }

    /**
     * @dev Return the index of the first (oldest) checkpoint with key greater or equal than the search key, or `high`
     * if there is none. `low` and `high` define a section where to do the search, with inclusive `low` and exclusive
     * `high`.
     *
     * WARNING: `high` should not be greater than the array's length.
     */
    function _lowerBinaryLookup(
        Checkpoint160[] storage self,
        uint96 key,
        uint256 low,
        uint256 high
    ) private view returns (uint256) {
        while (low < high) {
            uint256 mid = Math.average(low, high);
            if (_unsafeAccess(self, mid)._key < key) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return high;
    }

    /**
     * @dev Access an element of the array without performing bounds check. The position is assumed to be within bounds.
     */
    function _unsafeAccess(
        Checkpoint160[] storage self,
        uint256 pos
    ) private pure returns (Checkpoint160 storage result) {
        assembly {
            mstore(0, self.slot)
            result.slot := add(keccak256(0, 0x20), pos)
        }
    }
}


// File: lib/l1-contracts/src/core/libraries/compressed-data/fees/FeeStructs.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {CompressedSlot} from "@aztec/shared/libraries/CompressedTimeMath.sol";
import {SafeCast} from "@oz/utils/math/SafeCast.sol";

// We are using a type instead of a struct as we don't want to throw away a full 8 bits
// for the bool.
/*struct CompressedFeeHeader {
  uint1 preHeat;
  uint63 proverCost; Max value: 9.2233720369E18
  uint64 congestionCost;
  uint48 feeAssetPriceNumerator;
  uint48 excessMana;
  uint32 manaUsed;
}*/
type CompressedFeeHeader is uint256;

struct FeeHeader {
  uint256 excessMana;
  uint256 manaUsed;
  uint256 feeAssetPriceNumerator;
  uint256 congestionCost;
  uint256 proverCost;
}

struct L1FeeData {
  uint256 baseFee;
  uint256 blobFee;
}

// We compress the L1 fee data heavily, capping out at `2**56-1` (7.2057594038E16)
// If the costs rose to this point an eth transfer (21000 gas) would be
// 21000 * 2**56-1 = 1.5132094748E21 wei / 1,513 eth in fees.
type CompressedL1FeeData is uint112;

// (56 + 56) * 2 + 32 = 256
struct L1GasOracleValues {
  CompressedL1FeeData pre;
  CompressedL1FeeData post;
  CompressedSlot slotOfChange;
}

library FeeStructsLib {
  using SafeCast for uint256;

  uint256 internal constant MASK_56_BITS = 0xFFFFFFFFFFFFFF;

  function getBlobFee(CompressedL1FeeData _compressedL1FeeData) internal pure returns (uint256) {
    return CompressedL1FeeData.unwrap(_compressedL1FeeData) & MASK_56_BITS;
  }

  function getBaseFee(CompressedL1FeeData _compressedL1FeeData) internal pure returns (uint256) {
    return (CompressedL1FeeData.unwrap(_compressedL1FeeData) >> 56) & MASK_56_BITS;
  }

  function compress(L1FeeData memory _data) internal pure returns (CompressedL1FeeData) {
    uint256 value = 0;
    value |= uint256(_data.blobFee.toUint56()) << 0;
    value |= uint256(_data.baseFee.toUint56()) << 56;
    return CompressedL1FeeData.wrap(value.toUint112());
  }

  function decompress(CompressedL1FeeData _data) internal pure returns (L1FeeData memory) {
    uint256 value = CompressedL1FeeData.unwrap(_data);
    uint256 blobFee = value & MASK_56_BITS;
    uint256 baseFee = (value >> 56) & MASK_56_BITS;
    return L1FeeData({baseFee: uint256(baseFee), blobFee: uint256(blobFee)});
  }
}

library FeeHeaderLib {
  using SafeCast for uint256;

  uint256 internal constant MASK_32_BITS = 0xFFFFFFFF;
  uint256 internal constant MASK_48_BITS = 0xFFFFFFFFFFFF;
  uint256 internal constant MASK_63_BITS = 0x7FFFFFFFFFFFFFFF;
  uint256 internal constant MASK_64_BITS = 0xFFFFFFFFFFFFFFFF;

  function getManaUsed(CompressedFeeHeader _compressedFeeHeader) internal pure returns (uint256) {
    return CompressedFeeHeader.unwrap(_compressedFeeHeader) & MASK_32_BITS;
  }

  function getExcessMana(CompressedFeeHeader _compressedFeeHeader) internal pure returns (uint256) {
    return (CompressedFeeHeader.unwrap(_compressedFeeHeader) >> 32) & MASK_48_BITS;
  }

  function getFeeAssetPriceNumerator(CompressedFeeHeader _compressedFeeHeader) internal pure returns (uint256) {
    return (CompressedFeeHeader.unwrap(_compressedFeeHeader) >> 80) & MASK_48_BITS;
  }

  function getCongestionCost(CompressedFeeHeader _compressedFeeHeader) internal pure returns (uint256) {
    return (CompressedFeeHeader.unwrap(_compressedFeeHeader) >> 128) & MASK_64_BITS;
  }

  function getProverCost(CompressedFeeHeader _compressedFeeHeader) internal pure returns (uint256) {
    // The prover cost is only 63 bits so use mask to remove first bit
    return (CompressedFeeHeader.unwrap(_compressedFeeHeader) >> 192) & MASK_63_BITS;
  }

  function compress(FeeHeader memory _feeHeader) internal pure returns (CompressedFeeHeader) {
    uint256 value = 0;
    value |= uint256(_feeHeader.manaUsed.toUint32());
    value |= uint256(_feeHeader.excessMana.toUint48()) << 32;
    value |= uint256(_feeHeader.feeAssetPriceNumerator.toUint48()) << 80;
    value |= uint256(_feeHeader.congestionCost.toUint64()) << 128;

    uint256 proverCost = uint256(_feeHeader.proverCost.toUint64());
    require(proverCost == proverCost & MASK_63_BITS);
    value |= proverCost << 192;

    // Preheat
    value |= 1 << 255;

    return CompressedFeeHeader.wrap(value);
  }

  function decompress(CompressedFeeHeader _compressedFeeHeader) internal pure returns (FeeHeader memory) {
    uint256 value = CompressedFeeHeader.unwrap(_compressedFeeHeader);

    uint256 manaUsed = value & MASK_32_BITS;
    value >>= 32;
    uint256 excessMana = value & MASK_48_BITS;
    value >>= 48;
    uint256 feeAssetPriceNumerator = value & MASK_48_BITS;
    value >>= 48;
    uint256 congestionCost = value & MASK_64_BITS;
    value >>= 64;
    uint256 proverCost = value & MASK_63_BITS;

    return FeeHeader({
      manaUsed: uint256(manaUsed),
      excessMana: uint256(excessMana),
      feeAssetPriceNumerator: uint256(feeAssetPriceNumerator),
      congestionCost: uint256(congestionCost),
      proverCost: uint256(proverCost)
    });
  }
}


// File: lib/l1-contracts/src/core/libraries/rollup/BlobLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {Constants} from "@aztec/core/libraries/ConstantsGen.sol";
import {Hash} from "@aztec/core/libraries/crypto/Hash.sol";
import {Errors} from "@aztec/core/libraries/Errors.sol";

/**
 * @title BlobLib - Blob Management and Validation Library
 * @author Aztec Labs
 * @notice Core library for handling blob operations, validation, and commitment management in the Aztec rollup.
 *
 * @dev This library provides functionality for managing blobs:
 *      - Blob hash retrieval and validation against EIP-4844 specifications
 *      - Blob commitment verification and batched blob proof validation
 *      - Blob base fee retrieval for transaction cost calculations
 *      - Accumulated blob commitments hash calculation for epoch proofs
 *
 *      VM_ADDRESS:
 *      The VM_ADDRESS (0x7109709ECfa91a80626fF3989D68f67F5b1DD12D) is a special address used to detect
 *      when the contract is running in a Foundry test environment. This address is derived from
 *      keccak256("hevm cheat code") and corresponds to Foundry's VM contract that provides testing utilities.
 *      When block.chainid == 31337 &&  VM_ADDRESS.code.length > 0, it indicates we're in a test environment,
 *      allowing the library to:
 *      - Use Foundry's getBlobBaseFee() cheatcode instead of block.blobbasefee
 *      - Use Foundry's getBlobhashes() cheatcode instead of the blobhash() opcode
 *      This enables comprehensive testing of blob functionality without requiring actual blob transactions.
 *
 *      Blob Validation Flow:
 *      1. validateBlobs() processes L2 block blob data, extracting commitments and validating against real blobs
 *      2. calculateBlobCommitmentsHash() accumulates commitments across an epoch for rollup circuit validation
 *      3. validateBatchedBlob() verifies batched blob proofs using the EIP-4844 point evaluation precompile
 *      4. calculateBlobHash() computes versioned hashes from commitments following EIP-4844 specification
 */
library BlobLib {
  uint256 internal constant VERSIONED_HASH_VERSION_KZG =
    0x0100000000000000000000000000000000000000000000000000000000000000; // 0x01 << 248 to be used in blobHashCheck

  /**
   * @notice  Get the blob base fee
   *
   * @return uint256 - The blob base fee
   */
  function getBlobBaseFee() internal view returns (uint256) {
    return block.blobbasefee;
  }

  /**
   * @notice  Get the blob hash
   *
   * @return blobHash - The blob hash
   */
  function getBlobHash(uint256 _index) internal view returns (bytes32 blobHash) {
    assembly {
      blobHash := blobhash(_index)
    }
  }

  /**
   * @notice  Validate an L2 block's blobs and return the blobHashes, the hashed blobHashes, and blob commitments.
   *
   *          We assume that the Aztec related blobs will be first in the propose transaction, additional blobs can be
   *          at the end.
   *
   * Input bytes:
   * input[0] - num blobs in block
   * input[1:] - blob commitments (48 bytes * num blobs in block)
   * @param _blobsInput - The above bytes to verify our input blob commitments match real blobs
   * @param _checkBlob - Whether to skip blob related checks. Hardcoded to true (See RollupCore.sol -> checkBlob),
   * exists only to be overridden in tests.
   *
   * Returns for proposal:
   * @return blobHashes - All of the blob hashes included in this block, to be emitted in L2BlockProposed event.
   * @return blobsHashesCommitment - A hash of all blob hashes in this block, to be included in the block header. See
   * comment at the end of this fn for more info.
   * @return blobCommitments - All of the blob commitments included in this block, to be stored then validated against
   * those used in the rollup in epoch proof verification.
   */
  function validateBlobs(bytes calldata _blobsInput, bool _checkBlob)
    internal
    view
    returns (bytes32[] memory blobHashes, bytes32 blobsHashesCommitment, bytes[] memory blobCommitments)
  {
    // We cannot input the incorrect number of blobs below, as the blobsHash
    // and epoch proof verification will fail.
    uint8 numBlobs = uint8(_blobsInput[0]);
    require(numBlobs > 0, Errors.Rollup__NoBlobsInBlock());
    blobHashes = new bytes32[](numBlobs);
    blobCommitments = new bytes[](numBlobs);
    bytes32 blobHash;
    // Add 1 for the numBlobs prefix
    uint256 blobInputStart = 1;
    for (uint256 i = 0; i < numBlobs; i++) {
      // Commitments = arrays of bytes48 compressed points
      blobCommitments[i] =
        abi.encodePacked(_blobsInput[blobInputStart:blobInputStart + Constants.BLS12_POINT_COMPRESSED_BYTES]);
      blobInputStart += Constants.BLS12_POINT_COMPRESSED_BYTES;

      bytes32 blobHashCheck = calculateBlobHash(blobCommitments[i]);
      if (_checkBlob) {
        blobHash = getBlobHash(i);
        // The below check ensures that our injected blobCommitments indeed match the real
        // blobs submitted with this block. They are then used in the blobCommitmentsHash (see below).
        require(blobHash == blobHashCheck, Errors.Rollup__InvalidBlobHash(blobHash, blobHashCheck));
      } else {
        blobHash = blobHashCheck;
      }
      blobHashes[i] = blobHash;
    }
    // Hash the EVM blob hashes for the block header
    // TODO(#13430): The below blobsHashesCommitment known as blobsHash elsewhere in the code. The name
    // blobsHashesCommitment is confusingly similar to blobCommitmentsHash
    // which are different values:
    // - blobsHash := sha256([blobhash_0, ..., blobhash_m]) = a hash of all blob hashes in a block with m+1 blobs
    // inserted into the header, exists so a user can cross check blobs.
    // - blobCommitmentsHash := sha256( ...sha256(sha256(C_0), C_1) ... C_n) = iteratively calculated hash of all blob
    // commitments in an epoch with n+1 blobs (see calculateBlobCommitmentsHash()),
    //   exists so we can validate injected commitments to the rollup circuits correspond to the correct real blobs.
    // We may be able to combine these values e.g. blobCommitmentsHash := sha256( ...sha256(sha256(blobshash_0),
    // blobshash_1) ... blobshash_l) for an epoch with l+1 blocks.
    blobsHashesCommitment = Hash.sha256ToField(abi.encodePacked(blobHashes));
  }

  /**
   * @notice  Validate a batched blob.
   * Input bytes:
   * input[:32]     - versioned_hash - NB for a batched blob, this is simply the versioned hash of the batched
   * commitment
   * input[32:64]   - z = poseidon2( ...poseidon2(poseidon2(z_0, z_1), z_2) ... z_n)
   * input[64:96]   - y = y_0 + gamma * y_1 + gamma^2 * y_2 + ... + gamma^n * y_n
   * input[96:144]  - commitment C = C_0 + gamma * C_1 + gamma^2 * C_2 + ... + gamma^n * C_n
   * input[144:192] - proof (a commitment to the quotient polynomial q(X)) = Q_0 + gamma * Q_1 + gamma^2 * Q_2 + ... +
   * gamma^n * Q_n
   * @param _blobInput - The above bytes to verify a batched blob
   *
   * If this function passes where the values of z, y, and C are valid public inputs to the final epoch root proof, then
   * we know that the data in each blob of the epoch corresponds to the tx effects of all our proven txs in the epoch.
   *
   * The rollup circuits calculate each z_i and y_i as above, so if this function passes but they do not match the
   * values from the circuit, then proof verification will fail.
   *
   * Each commitment C_i is injected into the circuits and their correctness is validated using the blobCommitmentsHash,
   * as explained below in calculateBlobCommitmentsHash().
   *
   */
  function validateBatchedBlob(bytes calldata _blobInput) internal view returns (bool success) {
    // Staticcall the point eval precompile https://eips.ethereum.org/EIPS/eip-4844#point-evaluation-precompile :
    (success,) = address(0x0a).staticcall(_blobInput);
    require(success, Errors.Rollup__InvalidBlobProof(bytes32(_blobInput[0:32])));
  }

  /**
   * @notice  Calculate the current state of the blobCommitmentsHash. Called for each new proposed block.
   * @param _previousBlobCommitmentsHash - The previous block's blobCommitmentsHash.
   * @param _blobCommitments - The commitments corresponding to this block's blobs.
   * @param _isFirstBlockOfEpoch - Whether this block is the first of an epoch (see below).
   *
   * The blobCommitmentsHash is an accumulated value calculated in the rollup circuits as:
   *    blobCommitmentsHash_i := sha256(blobCommitmentsHash_(i - 1), C_i)
   * for each blob commitment C_i in an epoch. For the first blob in the epoch (i = 0):
   *    blobCommitmentsHash_i := sha256(C_0)
   * which is why we require _isFirstBlockOfEpoch here.
   *
   * Each blob commitment is injected into the rollup circuits and we rely on the L1 contracts to validate
   * these commitments correspond to real blobs. The input _blobCommitments below come from validateBlobs()
   * so we know they are valid commitments here.
   *
   * We recalculate the same blobCommitmentsHash (which encompasses all claimed blobs in the epoch)
   * as in the rollup circuits, then use the final value as a public input to the root rollup proof
   * verification in EpochProofLib.sol.
   *
   * If the proof verifies, we know that the injected commitments used in the rollup circuits match
   * the real commitments to L1 blobs.
   *
   */
  function calculateBlobCommitmentsHash(
    bytes32 _previousBlobCommitmentsHash,
    bytes[] memory _blobCommitments,
    bool _isFirstBlockOfEpoch
  ) internal pure returns (bytes32 currentBlobCommitmentsHash) {
    uint256 i = 0;
    currentBlobCommitmentsHash = _previousBlobCommitmentsHash;
    // If we are at the first block of an epoch, we reinitialize the blobCommitmentsHash.
    // Blob commitments are collected and proven per root rollup proof => per epoch.
    if (_isFirstBlockOfEpoch) {
      // Initialize the blobCommitmentsHash
      currentBlobCommitmentsHash = Hash.sha256ToField(abi.encodePacked(_blobCommitments[i++]));
    }
    for (i; i < _blobCommitments.length; i++) {
      currentBlobCommitmentsHash = Hash.sha256ToField(abi.encodePacked(currentBlobCommitmentsHash, _blobCommitments[i]));
    }
  }

  /**
   * @notice  Calculate the expected blob hash given a blob commitment
   * @dev TODO(#14646): Use kzg_to_versioned_hash & VERSIONED_HASH_VERSION_KZG
   * Until we use an external kzg_to_versioned_hash(), calculating it here:
   * EIP-4844 spec blobhash is 32 bytes: [version, ...sha256(commitment)[1:32]]
   * The version = VERSIONED_HASH_VERSION_KZG, currently 0x01.
   * @param _blobCommitment - The 48 byte blob commitment
   * @return bytes32 - The blob hash
   */
  function calculateBlobHash(bytes memory _blobCommitment) internal pure returns (bytes32) {
    return bytes32(
      (uint256(sha256(_blobCommitment)) & 0x00FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        | VERSIONED_HASH_VERSION_KZG
    );
  }
}


// File: lib/l1-contracts/src/core/libraries/compressed-data/fees/FeeConfig.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {Math} from "@oz/utils/math/Math.sol";
import {SafeCast} from "@oz/utils/math/SafeCast.sol";

type EthValue is uint256;

type FeeAssetValue is uint256;

// Precision of 1e9
type FeeAssetPerEthE9 is uint256;

function addEthValue(EthValue _a, EthValue _b) pure returns (EthValue) {
  return EthValue.wrap(EthValue.unwrap(_a) + EthValue.unwrap(_b));
}

function subEthValue(EthValue _a, EthValue _b) pure returns (EthValue) {
  return EthValue.wrap(EthValue.unwrap(_a) - EthValue.unwrap(_b));
}

using {addEthValue as +, subEthValue as -} for EthValue global;

// 64 bit manaTarget, 128 bit congestionUpdateFraction, 64 bit provingCostPerMana
type CompressedFeeConfig is uint256;

struct FeeConfig {
  uint256 manaTarget;
  uint256 congestionUpdateFraction;
  EthValue provingCostPerMana;
}

library PriceLib {
  function toEth(FeeAssetValue _feeAssetValue, FeeAssetPerEthE9 _feeAssetPerEth) internal pure returns (EthValue) {
    return EthValue.wrap(
      Math.mulDiv(
        FeeAssetValue.unwrap(_feeAssetValue), 1e9, FeeAssetPerEthE9.unwrap(_feeAssetPerEth), Math.Rounding.Ceil
      )
    );
  }

  function toFeeAsset(EthValue _ethValue, FeeAssetPerEthE9 _feeAssetPerEth) internal pure returns (FeeAssetValue) {
    return FeeAssetValue.wrap(
      Math.mulDiv(EthValue.unwrap(_ethValue), FeeAssetPerEthE9.unwrap(_feeAssetPerEth), 1e9, Math.Rounding.Ceil)
    );
  }
}

library FeeConfigLib {
  using SafeCast for uint256;

  uint256 private constant MASK_64_BITS = 0xFFFFFFFFFFFFFFFF;
  uint256 private constant MASK_128_BITS = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

  function getManaTarget(CompressedFeeConfig _compressedFeeConfig) internal pure returns (uint256) {
    return (CompressedFeeConfig.unwrap(_compressedFeeConfig) >> 192) & MASK_64_BITS;
  }

  function getCongestionUpdateFraction(CompressedFeeConfig _compressedFeeConfig) internal pure returns (uint256) {
    return (CompressedFeeConfig.unwrap(_compressedFeeConfig) >> 64) & MASK_128_BITS;
  }

  function getProvingCostPerMana(CompressedFeeConfig _compressedFeeConfig) internal pure returns (EthValue) {
    return EthValue.wrap(CompressedFeeConfig.unwrap(_compressedFeeConfig) & MASK_64_BITS);
  }

  function compress(FeeConfig memory _config) internal pure returns (CompressedFeeConfig) {
    uint256 value = 0;
    value |= uint256(EthValue.unwrap(_config.provingCostPerMana).toUint64());
    value |= uint256(_config.congestionUpdateFraction.toUint128()) << 64;
    value |= uint256(_config.manaTarget.toUint64()) << 192;

    return CompressedFeeConfig.wrap(value);
  }

  function decompress(CompressedFeeConfig _compressedFeeConfig) internal pure returns (FeeConfig memory) {
    return FeeConfig({
      provingCostPerMana: getProvingCostPerMana(_compressedFeeConfig),
      congestionUpdateFraction: getCongestionUpdateFraction(_compressedFeeConfig),
      manaTarget: getManaTarget(_compressedFeeConfig)
    });
  }
}


// File: lib/openzeppelin-contracts/contracts/utils/math/Math.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.3.0) (utils/math/Math.sol)

pragma solidity ^0.8.20;

import {Panic} from "../Panic.sol";
import {SafeCast} from "./SafeCast.sol";

/**
 * @dev Standard math utilities missing in the Solidity language.
 */
library Math {
    enum Rounding {
        Floor, // Toward negative infinity
        Ceil, // Toward positive infinity
        Trunc, // Toward zero
        Expand // Away from zero
    }

    /**
     * @dev Return the 512-bit addition of two uint256.
     *
     * The result is stored in two 256 variables such that sum = high * 2²⁵⁶ + low.
     */
    function add512(uint256 a, uint256 b) internal pure returns (uint256 high, uint256 low) {
        assembly ("memory-safe") {
            low := add(a, b)
            high := lt(low, a)
        }
    }

    /**
     * @dev Return the 512-bit multiplication of two uint256.
     *
     * The result is stored in two 256 variables such that product = high * 2²⁵⁶ + low.
     */
    function mul512(uint256 a, uint256 b) internal pure returns (uint256 high, uint256 low) {
        // 512-bit multiply [high low] = x * y. Compute the product mod 2²⁵⁶ and mod 2²⁵⁶ - 1, then use
        // the Chinese Remainder Theorem to reconstruct the 512 bit result. The result is stored in two 256
        // variables such that product = high * 2²⁵⁶ + low.
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            low := mul(a, b)
            high := sub(sub(mm, low), lt(mm, low))
        }
    }

    /**
     * @dev Returns the addition of two unsigned integers, with a success flag (no overflow).
     */
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool success, uint256 result) {
        unchecked {
            uint256 c = a + b;
            success = c >= a;
            result = c * SafeCast.toUint(success);
        }
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, with a success flag (no overflow).
     */
    function trySub(uint256 a, uint256 b) internal pure returns (bool success, uint256 result) {
        unchecked {
            uint256 c = a - b;
            success = c <= a;
            result = c * SafeCast.toUint(success);
        }
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with a success flag (no overflow).
     */
    function tryMul(uint256 a, uint256 b) internal pure returns (bool success, uint256 result) {
        unchecked {
            uint256 c = a * b;
            assembly ("memory-safe") {
                // Only true when the multiplication doesn't overflow
                // (c / a == b) || (a == 0)
                success := or(eq(div(c, a), b), iszero(a))
            }
            // equivalent to: success ? c : 0
            result = c * SafeCast.toUint(success);
        }
    }

    /**
     * @dev Returns the division of two unsigned integers, with a success flag (no division by zero).
     */
    function tryDiv(uint256 a, uint256 b) internal pure returns (bool success, uint256 result) {
        unchecked {
            success = b > 0;
            assembly ("memory-safe") {
                // The `DIV` opcode returns zero when the denominator is 0.
                result := div(a, b)
            }
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a success flag (no division by zero).
     */
    function tryMod(uint256 a, uint256 b) internal pure returns (bool success, uint256 result) {
        unchecked {
            success = b > 0;
            assembly ("memory-safe") {
                // The `MOD` opcode returns zero when the denominator is 0.
                result := mod(a, b)
            }
        }
    }

    /**
     * @dev Unsigned saturating addition, bounds to `2²⁵⁶ - 1` instead of overflowing.
     */
    function saturatingAdd(uint256 a, uint256 b) internal pure returns (uint256) {
        (bool success, uint256 result) = tryAdd(a, b);
        return ternary(success, result, type(uint256).max);
    }

    /**
     * @dev Unsigned saturating subtraction, bounds to zero instead of overflowing.
     */
    function saturatingSub(uint256 a, uint256 b) internal pure returns (uint256) {
        (, uint256 result) = trySub(a, b);
        return result;
    }

    /**
     * @dev Unsigned saturating multiplication, bounds to `2²⁵⁶ - 1` instead of overflowing.
     */
    function saturatingMul(uint256 a, uint256 b) internal pure returns (uint256) {
        (bool success, uint256 result) = tryMul(a, b);
        return ternary(success, result, type(uint256).max);
    }

    /**
     * @dev Branchless ternary evaluation for `a ? b : c`. Gas costs are constant.
     *
     * IMPORTANT: This function may reduce bytecode size and consume less gas when used standalone.
     * However, the compiler may optimize Solidity ternary operations (i.e. `a ? b : c`) to only compute
     * one branch when needed, making this function more expensive.
     */
    function ternary(bool condition, uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            // branchless ternary works because:
            // b ^ (a ^ b) == a
            // b ^ 0 == b
            return b ^ ((a ^ b) * SafeCast.toUint(condition));
        }
    }

    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return ternary(a > b, a, b);
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return ternary(a < b, a, b);
    }

    /**
     * @dev Returns the average of two numbers. The result is rounded towards
     * zero.
     */
    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b) / 2 can overflow.
        return (a & b) + (a ^ b) / 2;
    }

    /**
     * @dev Returns the ceiling of the division of two numbers.
     *
     * This differs from standard division with `/` in that it rounds towards infinity instead
     * of rounding towards zero.
     */
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) {
            // Guarantee the same behavior as in a regular Solidity division.
            Panic.panic(Panic.DIVISION_BY_ZERO);
        }

        // The following calculation ensures accurate ceiling division without overflow.
        // Since a is non-zero, (a - 1) / b will not overflow.
        // The largest possible result occurs when (a - 1) / b is type(uint256).max,
        // but the largest value we can obtain is type(uint256).max - 1, which happens
        // when a = type(uint256).max and b = 1.
        unchecked {
            return SafeCast.toUint(a > 0) * ((a - 1) / b + 1);
        }
    }

    /**
     * @dev Calculates floor(x * y / denominator) with full precision. Throws if result overflows a uint256 or
     * denominator == 0.
     *
     * Original credit to Remco Bloemen under MIT license (https://xn--2-umb.com/21/muldiv) with further edits by
     * Uniswap Labs also under MIT license.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            (uint256 high, uint256 low) = mul512(x, y);

            // Handle non-overflow cases, 256 by 256 division.
            if (high == 0) {
                // Solidity will revert if denominator == 0, unlike the div opcode on its own.
                // The surrounding unchecked block does not change this fact.
                // See https://docs.soliditylang.org/en/latest/control-structures.html#checked-or-unchecked-arithmetic.
                return low / denominator;
            }

            // Make sure the result is less than 2²⁵⁶. Also prevents denominator == 0.
            if (denominator <= high) {
                Panic.panic(ternary(denominator == 0, Panic.DIVISION_BY_ZERO, Panic.UNDER_OVERFLOW));
            }

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [high low].
            uint256 remainder;
            assembly ("memory-safe") {
                // Compute remainder using mulmod.
                remainder := mulmod(x, y, denominator)

                // Subtract 256 bit number from 512 bit number.
                high := sub(high, gt(remainder, low))
                low := sub(low, remainder)
            }

            // Factor powers of two out of denominator and compute largest power of two divisor of denominator.
            // Always >= 1. See https://cs.stackexchange.com/q/138556/92363.

            uint256 twos = denominator & (0 - denominator);
            assembly ("memory-safe") {
                // Divide denominator by twos.
                denominator := div(denominator, twos)

                // Divide [high low] by twos.
                low := div(low, twos)

                // Flip twos such that it is 2²⁵⁶ / twos. If twos is zero, then it becomes one.
                twos := add(div(sub(0, twos), twos), 1)
            }

            // Shift in bits from high into low.
            low |= high * twos;

            // Invert denominator mod 2²⁵⁶. Now that denominator is an odd number, it has an inverse modulo 2²⁵⁶ such
            // that denominator * inv ≡ 1 mod 2²⁵⁶. Compute the inverse by starting with a seed that is correct for
            // four bits. That is, denominator * inv ≡ 1 mod 2⁴.
            uint256 inverse = (3 * denominator) ^ 2;

            // Use the Newton-Raphson iteration to improve the precision. Thanks to Hensel's lifting lemma, this also
            // works in modular arithmetic, doubling the correct bits in each step.
            inverse *= 2 - denominator * inverse; // inverse mod 2⁸
            inverse *= 2 - denominator * inverse; // inverse mod 2¹⁶
            inverse *= 2 - denominator * inverse; // inverse mod 2³²
            inverse *= 2 - denominator * inverse; // inverse mod 2⁶⁴
            inverse *= 2 - denominator * inverse; // inverse mod 2¹²⁸
            inverse *= 2 - denominator * inverse; // inverse mod 2²⁵⁶

            // Because the division is now exact we can divide by multiplying with the modular inverse of denominator.
            // This will give us the correct result modulo 2²⁵⁶. Since the preconditions guarantee that the outcome is
            // less than 2²⁵⁶, this is the final result. We don't need to compute the high bits of the result and high
            // is no longer required.
            result = low * inverse;
            return result;
        }
    }

    /**
     * @dev Calculates x * y / denominator with full precision, following the selected rounding direction.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator, Rounding rounding) internal pure returns (uint256) {
        return mulDiv(x, y, denominator) + SafeCast.toUint(unsignedRoundsUp(rounding) && mulmod(x, y, denominator) > 0);
    }

    /**
     * @dev Calculates floor(x * y >> n) with full precision. Throws if result overflows a uint256.
     */
    function mulShr(uint256 x, uint256 y, uint8 n) internal pure returns (uint256 result) {
        unchecked {
            (uint256 high, uint256 low) = mul512(x, y);
            if (high >= 1 << n) {
                Panic.panic(Panic.UNDER_OVERFLOW);
            }
            return (high << (256 - n)) | (low >> n);
        }
    }

    /**
     * @dev Calculates x * y >> n with full precision, following the selected rounding direction.
     */
    function mulShr(uint256 x, uint256 y, uint8 n, Rounding rounding) internal pure returns (uint256) {
        return mulShr(x, y, n) + SafeCast.toUint(unsignedRoundsUp(rounding) && mulmod(x, y, 1 << n) > 0);
    }

    /**
     * @dev Calculate the modular multiplicative inverse of a number in Z/nZ.
     *
     * If n is a prime, then Z/nZ is a field. In that case all elements are inversible, except 0.
     * If n is not a prime, then Z/nZ is not a field, and some elements might not be inversible.
     *
     * If the input value is not inversible, 0 is returned.
     *
     * NOTE: If you know for sure that n is (big) a prime, it may be cheaper to use Fermat's little theorem and get the
     * inverse using `Math.modExp(a, n - 2, n)`. See {invModPrime}.
     */
    function invMod(uint256 a, uint256 n) internal pure returns (uint256) {
        unchecked {
            if (n == 0) return 0;

            // The inverse modulo is calculated using the Extended Euclidean Algorithm (iterative version)
            // Used to compute integers x and y such that: ax + ny = gcd(a, n).
            // When the gcd is 1, then the inverse of a modulo n exists and it's x.
            // ax + ny = 1
            // ax = 1 + (-y)n
            // ax ≡ 1 (mod n) # x is the inverse of a modulo n

            // If the remainder is 0 the gcd is n right away.
            uint256 remainder = a % n;
            uint256 gcd = n;

            // Therefore the initial coefficients are:
            // ax + ny = gcd(a, n) = n
            // 0a + 1n = n
            int256 x = 0;
            int256 y = 1;

            while (remainder != 0) {
                uint256 quotient = gcd / remainder;

                (gcd, remainder) = (
                    // The old remainder is the next gcd to try.
                    remainder,
                    // Compute the next remainder.
                    // Can't overflow given that (a % gcd) * (gcd // (a % gcd)) <= gcd
                    // where gcd is at most n (capped to type(uint256).max)
                    gcd - remainder * quotient
                );

                (x, y) = (
                    // Increment the coefficient of a.
                    y,
                    // Decrement the coefficient of n.
                    // Can overflow, but the result is casted to uint256 so that the
                    // next value of y is "wrapped around" to a value between 0 and n - 1.
                    x - y * int256(quotient)
                );
            }

            if (gcd != 1) return 0; // No inverse exists.
            return ternary(x < 0, n - uint256(-x), uint256(x)); // Wrap the result if it's negative.
        }
    }

    /**
     * @dev Variant of {invMod}. More efficient, but only works if `p` is known to be a prime greater than `2`.
     *
     * From https://en.wikipedia.org/wiki/Fermat%27s_little_theorem[Fermat's little theorem], we know that if p is
     * prime, then `a**(p-1) ≡ 1 mod p`. As a consequence, we have `a * a**(p-2) ≡ 1 mod p`, which means that
     * `a**(p-2)` is the modular multiplicative inverse of a in Fp.
     *
     * NOTE: this function does NOT check that `p` is a prime greater than `2`.
     */
    function invModPrime(uint256 a, uint256 p) internal view returns (uint256) {
        unchecked {
            return Math.modExp(a, p - 2, p);
        }
    }

    /**
     * @dev Returns the modular exponentiation of the specified base, exponent and modulus (b ** e % m)
     *
     * Requirements:
     * - modulus can't be zero
     * - underlying staticcall to precompile must succeed
     *
     * IMPORTANT: The result is only valid if the underlying call succeeds. When using this function, make
     * sure the chain you're using it on supports the precompiled contract for modular exponentiation
     * at address 0x05 as specified in https://eips.ethereum.org/EIPS/eip-198[EIP-198]. Otherwise,
     * the underlying function will succeed given the lack of a revert, but the result may be incorrectly
     * interpreted as 0.
     */
    function modExp(uint256 b, uint256 e, uint256 m) internal view returns (uint256) {
        (bool success, uint256 result) = tryModExp(b, e, m);
        if (!success) {
            Panic.panic(Panic.DIVISION_BY_ZERO);
        }
        return result;
    }

    /**
     * @dev Returns the modular exponentiation of the specified base, exponent and modulus (b ** e % m).
     * It includes a success flag indicating if the operation succeeded. Operation will be marked as failed if trying
     * to operate modulo 0 or if the underlying precompile reverted.
     *
     * IMPORTANT: The result is only valid if the success flag is true. When using this function, make sure the chain
     * you're using it on supports the precompiled contract for modular exponentiation at address 0x05 as specified in
     * https://eips.ethereum.org/EIPS/eip-198[EIP-198]. Otherwise, the underlying function will succeed given the lack
     * of a revert, but the result may be incorrectly interpreted as 0.
     */
    function tryModExp(uint256 b, uint256 e, uint256 m) internal view returns (bool success, uint256 result) {
        if (m == 0) return (false, 0);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            // | Offset    | Content    | Content (Hex)                                                      |
            // |-----------|------------|--------------------------------------------------------------------|
            // | 0x00:0x1f | size of b  | 0x0000000000000000000000000000000000000000000000000000000000000020 |
            // | 0x20:0x3f | size of e  | 0x0000000000000000000000000000000000000000000000000000000000000020 |
            // | 0x40:0x5f | size of m  | 0x0000000000000000000000000000000000000000000000000000000000000020 |
            // | 0x60:0x7f | value of b | 0x<.............................................................b> |
            // | 0x80:0x9f | value of e | 0x<.............................................................e> |
            // | 0xa0:0xbf | value of m | 0x<.............................................................m> |
            mstore(ptr, 0x20)
            mstore(add(ptr, 0x20), 0x20)
            mstore(add(ptr, 0x40), 0x20)
            mstore(add(ptr, 0x60), b)
            mstore(add(ptr, 0x80), e)
            mstore(add(ptr, 0xa0), m)

            // Given the result < m, it's guaranteed to fit in 32 bytes,
            // so we can use the memory scratch space located at offset 0.
            success := staticcall(gas(), 0x05, ptr, 0xc0, 0x00, 0x20)
            result := mload(0x00)
        }
    }

    /**
     * @dev Variant of {modExp} that supports inputs of arbitrary length.
     */
    function modExp(bytes memory b, bytes memory e, bytes memory m) internal view returns (bytes memory) {
        (bool success, bytes memory result) = tryModExp(b, e, m);
        if (!success) {
            Panic.panic(Panic.DIVISION_BY_ZERO);
        }
        return result;
    }

    /**
     * @dev Variant of {tryModExp} that supports inputs of arbitrary length.
     */
    function tryModExp(
        bytes memory b,
        bytes memory e,
        bytes memory m
    ) internal view returns (bool success, bytes memory result) {
        if (_zeroBytes(m)) return (false, new bytes(0));

        uint256 mLen = m.length;

        // Encode call args in result and move the free memory pointer
        result = abi.encodePacked(b.length, e.length, mLen, b, e, m);

        assembly ("memory-safe") {
            let dataPtr := add(result, 0x20)
            // Write result on top of args to avoid allocating extra memory.
            success := staticcall(gas(), 0x05, dataPtr, mload(result), dataPtr, mLen)
            // Overwrite the length.
            // result.length > returndatasize() is guaranteed because returndatasize() == m.length
            mstore(result, mLen)
            // Set the memory pointer after the returned data.
            mstore(0x40, add(dataPtr, mLen))
        }
    }

    /**
     * @dev Returns whether the provided byte array is zero.
     */
    function _zeroBytes(bytes memory byteArray) private pure returns (bool) {
        for (uint256 i = 0; i < byteArray.length; ++i) {
            if (byteArray[i] != 0) {
                return false;
            }
        }
        return true;
    }

    /**
     * @dev Returns the square root of a number. If the number is not a perfect square, the value is rounded
     * towards zero.
     *
     * This method is based on Newton's method for computing square roots; the algorithm is restricted to only
     * using integer operations.
     */
    function sqrt(uint256 a) internal pure returns (uint256) {
        unchecked {
            // Take care of easy edge cases when a == 0 or a == 1
            if (a <= 1) {
                return a;
            }

            // In this function, we use Newton's method to get a root of `f(x) := x² - a`. It involves building a
            // sequence x_n that converges toward sqrt(a). For each iteration x_n, we also define the error between
            // the current value as `ε_n = | x_n - sqrt(a) |`.
            //
            // For our first estimation, we consider `e` the smallest power of 2 which is bigger than the square root
            // of the target. (i.e. `2**(e-1) ≤ sqrt(a) < 2**e`). We know that `e ≤ 128` because `(2¹²⁸)² = 2²⁵⁶` is
            // bigger than any uint256.
            //
            // By noticing that
            // `2**(e-1) ≤ sqrt(a) < 2**e → (2**(e-1))² ≤ a < (2**e)² → 2**(2*e-2) ≤ a < 2**(2*e)`
            // we can deduce that `e - 1` is `log2(a) / 2`. We can thus compute `x_n = 2**(e-1)` using a method similar
            // to the msb function.
            uint256 aa = a;
            uint256 xn = 1;

            if (aa >= (1 << 128)) {
                aa >>= 128;
                xn <<= 64;
            }
            if (aa >= (1 << 64)) {
                aa >>= 64;
                xn <<= 32;
            }
            if (aa >= (1 << 32)) {
                aa >>= 32;
                xn <<= 16;
            }
            if (aa >= (1 << 16)) {
                aa >>= 16;
                xn <<= 8;
            }
            if (aa >= (1 << 8)) {
                aa >>= 8;
                xn <<= 4;
            }
            if (aa >= (1 << 4)) {
                aa >>= 4;
                xn <<= 2;
            }
            if (aa >= (1 << 2)) {
                xn <<= 1;
            }

            // We now have x_n such that `x_n = 2**(e-1) ≤ sqrt(a) < 2**e = 2 * x_n`. This implies ε_n ≤ 2**(e-1).
            //
            // We can refine our estimation by noticing that the middle of that interval minimizes the error.
            // If we move x_n to equal 2**(e-1) + 2**(e-2), then we reduce the error to ε_n ≤ 2**(e-2).
            // This is going to be our x_0 (and ε_0)
            xn = (3 * xn) >> 1; // ε_0 := | x_0 - sqrt(a) | ≤ 2**(e-2)

            // From here, Newton's method give us:
            // x_{n+1} = (x_n + a / x_n) / 2
            //
            // One should note that:
            // x_{n+1}² - a = ((x_n + a / x_n) / 2)² - a
            //              = ((x_n² + a) / (2 * x_n))² - a
            //              = (x_n⁴ + 2 * a * x_n² + a²) / (4 * x_n²) - a
            //              = (x_n⁴ + 2 * a * x_n² + a² - 4 * a * x_n²) / (4 * x_n²)
            //              = (x_n⁴ - 2 * a * x_n² + a²) / (4 * x_n²)
            //              = (x_n² - a)² / (2 * x_n)²
            //              = ((x_n² - a) / (2 * x_n))²
            //              ≥ 0
            // Which proves that for all n ≥ 1, sqrt(a) ≤ x_n
            //
            // This gives us the proof of quadratic convergence of the sequence:
            // ε_{n+1} = | x_{n+1} - sqrt(a) |
            //         = | (x_n + a / x_n) / 2 - sqrt(a) |
            //         = | (x_n² + a - 2*x_n*sqrt(a)) / (2 * x_n) |
            //         = | (x_n - sqrt(a))² / (2 * x_n) |
            //         = | ε_n² / (2 * x_n) |
            //         = ε_n² / | (2 * x_n) |
            //
            // For the first iteration, we have a special case where x_0 is known:
            // ε_1 = ε_0² / | (2 * x_0) |
            //     ≤ (2**(e-2))² / (2 * (2**(e-1) + 2**(e-2)))
            //     ≤ 2**(2*e-4) / (3 * 2**(e-1))
            //     ≤ 2**(e-3) / 3
            //     ≤ 2**(e-3-log2(3))
            //     ≤ 2**(e-4.5)
            //
            // For the following iterations, we use the fact that, 2**(e-1) ≤ sqrt(a) ≤ x_n:
            // ε_{n+1} = ε_n² / | (2 * x_n) |
            //         ≤ (2**(e-k))² / (2 * 2**(e-1))
            //         ≤ 2**(2*e-2*k) / 2**e
            //         ≤ 2**(e-2*k)
            xn = (xn + a / xn) >> 1; // ε_1 := | x_1 - sqrt(a) | ≤ 2**(e-4.5)  -- special case, see above
            xn = (xn + a / xn) >> 1; // ε_2 := | x_2 - sqrt(a) | ≤ 2**(e-9)    -- general case with k = 4.5
            xn = (xn + a / xn) >> 1; // ε_3 := | x_3 - sqrt(a) | ≤ 2**(e-18)   -- general case with k = 9
            xn = (xn + a / xn) >> 1; // ε_4 := | x_4 - sqrt(a) | ≤ 2**(e-36)   -- general case with k = 18
            xn = (xn + a / xn) >> 1; // ε_5 := | x_5 - sqrt(a) | ≤ 2**(e-72)   -- general case with k = 36
            xn = (xn + a / xn) >> 1; // ε_6 := | x_6 - sqrt(a) | ≤ 2**(e-144)  -- general case with k = 72

            // Because e ≤ 128 (as discussed during the first estimation phase), we know have reached a precision
            // ε_6 ≤ 2**(e-144) < 1. Given we're operating on integers, then we can ensure that xn is now either
            // sqrt(a) or sqrt(a) + 1.
            return xn - SafeCast.toUint(xn > a / xn);
        }
    }

    /**
     * @dev Calculates sqrt(a), following the selected rounding direction.
     */
    function sqrt(uint256 a, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = sqrt(a);
            return result + SafeCast.toUint(unsignedRoundsUp(rounding) && result * result < a);
        }
    }

    /**
     * @dev Return the log in base 2 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     */
    function log2(uint256 x) internal pure returns (uint256 r) {
        // If value has upper 128 bits set, log2 result is at least 128
        r = SafeCast.toUint(x > 0xffffffffffffffffffffffffffffffff) << 7;
        // If upper 64 bits of 128-bit half set, add 64 to result
        r |= SafeCast.toUint((x >> r) > 0xffffffffffffffff) << 6;
        // If upper 32 bits of 64-bit half set, add 32 to result
        r |= SafeCast.toUint((x >> r) > 0xffffffff) << 5;
        // If upper 16 bits of 32-bit half set, add 16 to result
        r |= SafeCast.toUint((x >> r) > 0xffff) << 4;
        // If upper 8 bits of 16-bit half set, add 8 to result
        r |= SafeCast.toUint((x >> r) > 0xff) << 3;
        // If upper 4 bits of 8-bit half set, add 4 to result
        r |= SafeCast.toUint((x >> r) > 0xf) << 2;

        // Shifts value right by the current result and use it as an index into this lookup table:
        //
        // | x (4 bits) |  index  | table[index] = MSB position |
        // |------------|---------|-----------------------------|
        // |    0000    |    0    |        table[0] = 0         |
        // |    0001    |    1    |        table[1] = 0         |
        // |    0010    |    2    |        table[2] = 1         |
        // |    0011    |    3    |        table[3] = 1         |
        // |    0100    |    4    |        table[4] = 2         |
        // |    0101    |    5    |        table[5] = 2         |
        // |    0110    |    6    |        table[6] = 2         |
        // |    0111    |    7    |        table[7] = 2         |
        // |    1000    |    8    |        table[8] = 3         |
        // |    1001    |    9    |        table[9] = 3         |
        // |    1010    |   10    |        table[10] = 3        |
        // |    1011    |   11    |        table[11] = 3        |
        // |    1100    |   12    |        table[12] = 3        |
        // |    1101    |   13    |        table[13] = 3        |
        // |    1110    |   14    |        table[14] = 3        |
        // |    1111    |   15    |        table[15] = 3        |
        //
        // The lookup table is represented as a 32-byte value with the MSB positions for 0-15 in the last 16 bytes.
        assembly ("memory-safe") {
            r := or(r, byte(shr(r, x), 0x0000010102020202030303030303030300000000000000000000000000000000))
        }
    }

    /**
     * @dev Return the log in base 2, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log2(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log2(value);
            return result + SafeCast.toUint(unsignedRoundsUp(rounding) && 1 << result < value);
        }
    }

    /**
     * @dev Return the log in base 10 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     */
    function log10(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >= 10 ** 64) {
                value /= 10 ** 64;
                result += 64;
            }
            if (value >= 10 ** 32) {
                value /= 10 ** 32;
                result += 32;
            }
            if (value >= 10 ** 16) {
                value /= 10 ** 16;
                result += 16;
            }
            if (value >= 10 ** 8) {
                value /= 10 ** 8;
                result += 8;
            }
            if (value >= 10 ** 4) {
                value /= 10 ** 4;
                result += 4;
            }
            if (value >= 10 ** 2) {
                value /= 10 ** 2;
                result += 2;
            }
            if (value >= 10 ** 1) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 10, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log10(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log10(value);
            return result + SafeCast.toUint(unsignedRoundsUp(rounding) && 10 ** result < value);
        }
    }

    /**
     * @dev Return the log in base 256 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     *
     * Adding one to the result gives the number of pairs of hex symbols needed to represent `value` as a hex string.
     */
    function log256(uint256 x) internal pure returns (uint256 r) {
        // If value has upper 128 bits set, log2 result is at least 128
        r = SafeCast.toUint(x > 0xffffffffffffffffffffffffffffffff) << 7;
        // If upper 64 bits of 128-bit half set, add 64 to result
        r |= SafeCast.toUint((x >> r) > 0xffffffffffffffff) << 6;
        // If upper 32 bits of 64-bit half set, add 32 to result
        r |= SafeCast.toUint((x >> r) > 0xffffffff) << 5;
        // If upper 16 bits of 32-bit half set, add 16 to result
        r |= SafeCast.toUint((x >> r) > 0xffff) << 4;
        // Add 1 if upper 8 bits of 16-bit half set, and divide accumulated result by 8
        return (r >> 3) | SafeCast.toUint((x >> r) > 0xff);
    }

    /**
     * @dev Return the log in base 256, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log256(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log256(value);
            return result + SafeCast.toUint(unsignedRoundsUp(rounding) && 1 << (result << 3) < value);
        }
    }

    /**
     * @dev Returns whether a provided rounding mode is considered rounding up for unsigned integers.
     */
    function unsignedRoundsUp(Rounding rounding) internal pure returns (bool) {
        return uint8(rounding) % 2 == 1;
    }
}


// File: lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (utils/math/SafeCast.sol)
// This file was procedurally generated from scripts/generate/templates/SafeCast.js.

pragma solidity ^0.8.20;

/**
 * @dev Wrappers over Solidity's uintXX/intXX/bool casting operators with added overflow
 * checks.
 *
 * Downcasting from uint256/int256 in Solidity does not revert on overflow. This can
 * easily result in undesired exploitation or bugs, since developers usually
 * assume that overflows raise errors. `SafeCast` restores this intuition by
 * reverting the transaction when such an operation overflows.
 *
 * Using this library instead of the unchecked operations eliminates an entire
 * class of bugs, so it's recommended to use it always.
 */
library SafeCast {
    /**
     * @dev Value doesn't fit in an uint of `bits` size.
     */
    error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value);

    /**
     * @dev An int value doesn't fit in an uint of `bits` size.
     */
    error SafeCastOverflowedIntToUint(int256 value);

    /**
     * @dev Value doesn't fit in an int of `bits` size.
     */
    error SafeCastOverflowedIntDowncast(uint8 bits, int256 value);

    /**
     * @dev An uint value doesn't fit in an int of `bits` size.
     */
    error SafeCastOverflowedUintToInt(uint256 value);

    /**
     * @dev Returns the downcasted uint248 from uint256, reverting on
     * overflow (when the input is greater than largest uint248).
     *
     * Counterpart to Solidity's `uint248` operator.
     *
     * Requirements:
     *
     * - input must fit into 248 bits
     */
    function toUint248(uint256 value) internal pure returns (uint248) {
        if (value > type(uint248).max) {
            revert SafeCastOverflowedUintDowncast(248, value);
        }
        return uint248(value);
    }

    /**
     * @dev Returns the downcasted uint240 from uint256, reverting on
     * overflow (when the input is greater than largest uint240).
     *
     * Counterpart to Solidity's `uint240` operator.
     *
     * Requirements:
     *
     * - input must fit into 240 bits
     */
    function toUint240(uint256 value) internal pure returns (uint240) {
        if (value > type(uint240).max) {
            revert SafeCastOverflowedUintDowncast(240, value);
        }
        return uint240(value);
    }

    /**
     * @dev Returns the downcasted uint232 from uint256, reverting on
     * overflow (when the input is greater than largest uint232).
     *
     * Counterpart to Solidity's `uint232` operator.
     *
     * Requirements:
     *
     * - input must fit into 232 bits
     */
    function toUint232(uint256 value) internal pure returns (uint232) {
        if (value > type(uint232).max) {
            revert SafeCastOverflowedUintDowncast(232, value);
        }
        return uint232(value);
    }

    /**
     * @dev Returns the downcasted uint224 from uint256, reverting on
     * overflow (when the input is greater than largest uint224).
     *
     * Counterpart to Solidity's `uint224` operator.
     *
     * Requirements:
     *
     * - input must fit into 224 bits
     */
    function toUint224(uint256 value) internal pure returns (uint224) {
        if (value > type(uint224).max) {
            revert SafeCastOverflowedUintDowncast(224, value);
        }
        return uint224(value);
    }

    /**
     * @dev Returns the downcasted uint216 from uint256, reverting on
     * overflow (when the input is greater than largest uint216).
     *
     * Counterpart to Solidity's `uint216` operator.
     *
     * Requirements:
     *
     * - input must fit into 216 bits
     */
    function toUint216(uint256 value) internal pure returns (uint216) {
        if (value > type(uint216).max) {
            revert SafeCastOverflowedUintDowncast(216, value);
        }
        return uint216(value);
    }

    /**
     * @dev Returns the downcasted uint208 from uint256, reverting on
     * overflow (when the input is greater than largest uint208).
     *
     * Counterpart to Solidity's `uint208` operator.
     *
     * Requirements:
     *
     * - input must fit into 208 bits
     */
    function toUint208(uint256 value) internal pure returns (uint208) {
        if (value > type(uint208).max) {
            revert SafeCastOverflowedUintDowncast(208, value);
        }
        return uint208(value);
    }

    /**
     * @dev Returns the downcasted uint200 from uint256, reverting on
     * overflow (when the input is greater than largest uint200).
     *
     * Counterpart to Solidity's `uint200` operator.
     *
     * Requirements:
     *
     * - input must fit into 200 bits
     */
    function toUint200(uint256 value) internal pure returns (uint200) {
        if (value > type(uint200).max) {
            revert SafeCastOverflowedUintDowncast(200, value);
        }
        return uint200(value);
    }

    /**
     * @dev Returns the downcasted uint192 from uint256, reverting on
     * overflow (when the input is greater than largest uint192).
     *
     * Counterpart to Solidity's `uint192` operator.
     *
     * Requirements:
     *
     * - input must fit into 192 bits
     */
    function toUint192(uint256 value) internal pure returns (uint192) {
        if (value > type(uint192).max) {
            revert SafeCastOverflowedUintDowncast(192, value);
        }
        return uint192(value);
    }

    /**
     * @dev Returns the downcasted uint184 from uint256, reverting on
     * overflow (when the input is greater than largest uint184).
     *
     * Counterpart to Solidity's `uint184` operator.
     *
     * Requirements:
     *
     * - input must fit into 184 bits
     */
    function toUint184(uint256 value) internal pure returns (uint184) {
        if (value > type(uint184).max) {
            revert SafeCastOverflowedUintDowncast(184, value);
        }
        return uint184(value);
    }

    /**
     * @dev Returns the downcasted uint176 from uint256, reverting on
     * overflow (when the input is greater than largest uint176).
     *
     * Counterpart to Solidity's `uint176` operator.
     *
     * Requirements:
     *
     * - input must fit into 176 bits
     */
    function toUint176(uint256 value) internal pure returns (uint176) {
        if (value > type(uint176).max) {
            revert SafeCastOverflowedUintDowncast(176, value);
        }
        return uint176(value);
    }

    /**
     * @dev Returns the downcasted uint168 from uint256, reverting on
     * overflow (when the input is greater than largest uint168).
     *
     * Counterpart to Solidity's `uint168` operator.
     *
     * Requirements:
     *
     * - input must fit into 168 bits
     */
    function toUint168(uint256 value) internal pure returns (uint168) {
        if (value > type(uint168).max) {
            revert SafeCastOverflowedUintDowncast(168, value);
        }
        return uint168(value);
    }

    /**
     * @dev Returns the downcasted uint160 from uint256, reverting on
     * overflow (when the input is greater than largest uint160).
     *
     * Counterpart to Solidity's `uint160` operator.
     *
     * Requirements:
     *
     * - input must fit into 160 bits
     */
    function toUint160(uint256 value) internal pure returns (uint160) {
        if (value > type(uint160).max) {
            revert SafeCastOverflowedUintDowncast(160, value);
        }
        return uint160(value);
    }

    /**
     * @dev Returns the downcasted uint152 from uint256, reverting on
     * overflow (when the input is greater than largest uint152).
     *
     * Counterpart to Solidity's `uint152` operator.
     *
     * Requirements:
     *
     * - input must fit into 152 bits
     */
    function toUint152(uint256 value) internal pure returns (uint152) {
        if (value > type(uint152).max) {
            revert SafeCastOverflowedUintDowncast(152, value);
        }
        return uint152(value);
    }

    /**
     * @dev Returns the downcasted uint144 from uint256, reverting on
     * overflow (when the input is greater than largest uint144).
     *
     * Counterpart to Solidity's `uint144` operator.
     *
     * Requirements:
     *
     * - input must fit into 144 bits
     */
    function toUint144(uint256 value) internal pure returns (uint144) {
        if (value > type(uint144).max) {
            revert SafeCastOverflowedUintDowncast(144, value);
        }
        return uint144(value);
    }

    /**
     * @dev Returns the downcasted uint136 from uint256, reverting on
     * overflow (when the input is greater than largest uint136).
     *
     * Counterpart to Solidity's `uint136` operator.
     *
     * Requirements:
     *
     * - input must fit into 136 bits
     */
    function toUint136(uint256 value) internal pure returns (uint136) {
        if (value > type(uint136).max) {
            revert SafeCastOverflowedUintDowncast(136, value);
        }
        return uint136(value);
    }

    /**
     * @dev Returns the downcasted uint128 from uint256, reverting on
     * overflow (when the input is greater than largest uint128).
     *
     * Counterpart to Solidity's `uint128` operator.
     *
     * Requirements:
     *
     * - input must fit into 128 bits
     */
    function toUint128(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) {
            revert SafeCastOverflowedUintDowncast(128, value);
        }
        return uint128(value);
    }

    /**
     * @dev Returns the downcasted uint120 from uint256, reverting on
     * overflow (when the input is greater than largest uint120).
     *
     * Counterpart to Solidity's `uint120` operator.
     *
     * Requirements:
     *
     * - input must fit into 120 bits
     */
    function toUint120(uint256 value) internal pure returns (uint120) {
        if (value > type(uint120).max) {
            revert SafeCastOverflowedUintDowncast(120, value);
        }
        return uint120(value);
    }

    /**
     * @dev Returns the downcasted uint112 from uint256, reverting on
     * overflow (when the input is greater than largest uint112).
     *
     * Counterpart to Solidity's `uint112` operator.
     *
     * Requirements:
     *
     * - input must fit into 112 bits
     */
    function toUint112(uint256 value) internal pure returns (uint112) {
        if (value > type(uint112).max) {
            revert SafeCastOverflowedUintDowncast(112, value);
        }
        return uint112(value);
    }

    /**
     * @dev Returns the downcasted uint104 from uint256, reverting on
     * overflow (when the input is greater than largest uint104).
     *
     * Counterpart to Solidity's `uint104` operator.
     *
     * Requirements:
     *
     * - input must fit into 104 bits
     */
    function toUint104(uint256 value) internal pure returns (uint104) {
        if (value > type(uint104).max) {
            revert SafeCastOverflowedUintDowncast(104, value);
        }
        return uint104(value);
    }

    /**
     * @dev Returns the downcasted uint96 from uint256, reverting on
     * overflow (when the input is greater than largest uint96).
     *
     * Counterpart to Solidity's `uint96` operator.
     *
     * Requirements:
     *
     * - input must fit into 96 bits
     */
    function toUint96(uint256 value) internal pure returns (uint96) {
        if (value > type(uint96).max) {
            revert SafeCastOverflowedUintDowncast(96, value);
        }
        return uint96(value);
    }

    /**
     * @dev Returns the downcasted uint88 from uint256, reverting on
     * overflow (when the input is greater than largest uint88).
     *
     * Counterpart to Solidity's `uint88` operator.
     *
     * Requirements:
     *
     * - input must fit into 88 bits
     */
    function toUint88(uint256 value) internal pure returns (uint88) {
        if (value > type(uint88).max) {
            revert SafeCastOverflowedUintDowncast(88, value);
        }
        return uint88(value);
    }

    /**
     * @dev Returns the downcasted uint80 from uint256, reverting on
     * overflow (when the input is greater than largest uint80).
     *
     * Counterpart to Solidity's `uint80` operator.
     *
     * Requirements:
     *
     * - input must fit into 80 bits
     */
    function toUint80(uint256 value) internal pure returns (uint80) {
        if (value > type(uint80).max) {
            revert SafeCastOverflowedUintDowncast(80, value);
        }
        return uint80(value);
    }

    /**
     * @dev Returns the downcasted uint72 from uint256, reverting on
     * overflow (when the input is greater than largest uint72).
     *
     * Counterpart to Solidity's `uint72` operator.
     *
     * Requirements:
     *
     * - input must fit into 72 bits
     */
    function toUint72(uint256 value) internal pure returns (uint72) {
        if (value > type(uint72).max) {
            revert SafeCastOverflowedUintDowncast(72, value);
        }
        return uint72(value);
    }

    /**
     * @dev Returns the downcasted uint64 from uint256, reverting on
     * overflow (when the input is greater than largest uint64).
     *
     * Counterpart to Solidity's `uint64` operator.
     *
     * Requirements:
     *
     * - input must fit into 64 bits
     */
    function toUint64(uint256 value) internal pure returns (uint64) {
        if (value > type(uint64).max) {
            revert SafeCastOverflowedUintDowncast(64, value);
        }
        return uint64(value);
    }

    /**
     * @dev Returns the downcasted uint56 from uint256, reverting on
     * overflow (when the input is greater than largest uint56).
     *
     * Counterpart to Solidity's `uint56` operator.
     *
     * Requirements:
     *
     * - input must fit into 56 bits
     */
    function toUint56(uint256 value) internal pure returns (uint56) {
        if (value > type(uint56).max) {
            revert SafeCastOverflowedUintDowncast(56, value);
        }
        return uint56(value);
    }

    /**
     * @dev Returns the downcasted uint48 from uint256, reverting on
     * overflow (when the input is greater than largest uint48).
     *
     * Counterpart to Solidity's `uint48` operator.
     *
     * Requirements:
     *
     * - input must fit into 48 bits
     */
    function toUint48(uint256 value) internal pure returns (uint48) {
        if (value > type(uint48).max) {
            revert SafeCastOverflowedUintDowncast(48, value);
        }
        return uint48(value);
    }

    /**
     * @dev Returns the downcasted uint40 from uint256, reverting on
     * overflow (when the input is greater than largest uint40).
     *
     * Counterpart to Solidity's `uint40` operator.
     *
     * Requirements:
     *
     * - input must fit into 40 bits
     */
    function toUint40(uint256 value) internal pure returns (uint40) {
        if (value > type(uint40).max) {
            revert SafeCastOverflowedUintDowncast(40, value);
        }
        return uint40(value);
    }

    /**
     * @dev Returns the downcasted uint32 from uint256, reverting on
     * overflow (when the input is greater than largest uint32).
     *
     * Counterpart to Solidity's `uint32` operator.
     *
     * Requirements:
     *
     * - input must fit into 32 bits
     */
    function toUint32(uint256 value) internal pure returns (uint32) {
        if (value > type(uint32).max) {
            revert SafeCastOverflowedUintDowncast(32, value);
        }
        return uint32(value);
    }

    /**
     * @dev Returns the downcasted uint24 from uint256, reverting on
     * overflow (when the input is greater than largest uint24).
     *
     * Counterpart to Solidity's `uint24` operator.
     *
     * Requirements:
     *
     * - input must fit into 24 bits
     */
    function toUint24(uint256 value) internal pure returns (uint24) {
        if (value > type(uint24).max) {
            revert SafeCastOverflowedUintDowncast(24, value);
        }
        return uint24(value);
    }

    /**
     * @dev Returns the downcasted uint16 from uint256, reverting on
     * overflow (when the input is greater than largest uint16).
     *
     * Counterpart to Solidity's `uint16` operator.
     *
     * Requirements:
     *
     * - input must fit into 16 bits
     */
    function toUint16(uint256 value) internal pure returns (uint16) {
        if (value > type(uint16).max) {
            revert SafeCastOverflowedUintDowncast(16, value);
        }
        return uint16(value);
    }

    /**
     * @dev Returns the downcasted uint8 from uint256, reverting on
     * overflow (when the input is greater than largest uint8).
     *
     * Counterpart to Solidity's `uint8` operator.
     *
     * Requirements:
     *
     * - input must fit into 8 bits
     */
    function toUint8(uint256 value) internal pure returns (uint8) {
        if (value > type(uint8).max) {
            revert SafeCastOverflowedUintDowncast(8, value);
        }
        return uint8(value);
    }

    /**
     * @dev Converts a signed int256 into an unsigned uint256.
     *
     * Requirements:
     *
     * - input must be greater than or equal to 0.
     */
    function toUint256(int256 value) internal pure returns (uint256) {
        if (value < 0) {
            revert SafeCastOverflowedIntToUint(value);
        }
        return uint256(value);
    }

    /**
     * @dev Returns the downcasted int248 from int256, reverting on
     * overflow (when the input is less than smallest int248 or
     * greater than largest int248).
     *
     * Counterpart to Solidity's `int248` operator.
     *
     * Requirements:
     *
     * - input must fit into 248 bits
     */
    function toInt248(int256 value) internal pure returns (int248 downcasted) {
        downcasted = int248(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(248, value);
        }
    }

    /**
     * @dev Returns the downcasted int240 from int256, reverting on
     * overflow (when the input is less than smallest int240 or
     * greater than largest int240).
     *
     * Counterpart to Solidity's `int240` operator.
     *
     * Requirements:
     *
     * - input must fit into 240 bits
     */
    function toInt240(int256 value) internal pure returns (int240 downcasted) {
        downcasted = int240(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(240, value);
        }
    }

    /**
     * @dev Returns the downcasted int232 from int256, reverting on
     * overflow (when the input is less than smallest int232 or
     * greater than largest int232).
     *
     * Counterpart to Solidity's `int232` operator.
     *
     * Requirements:
     *
     * - input must fit into 232 bits
     */
    function toInt232(int256 value) internal pure returns (int232 downcasted) {
        downcasted = int232(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(232, value);
        }
    }

    /**
     * @dev Returns the downcasted int224 from int256, reverting on
     * overflow (when the input is less than smallest int224 or
     * greater than largest int224).
     *
     * Counterpart to Solidity's `int224` operator.
     *
     * Requirements:
     *
     * - input must fit into 224 bits
     */
    function toInt224(int256 value) internal pure returns (int224 downcasted) {
        downcasted = int224(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(224, value);
        }
    }

    /**
     * @dev Returns the downcasted int216 from int256, reverting on
     * overflow (when the input is less than smallest int216 or
     * greater than largest int216).
     *
     * Counterpart to Solidity's `int216` operator.
     *
     * Requirements:
     *
     * - input must fit into 216 bits
     */
    function toInt216(int256 value) internal pure returns (int216 downcasted) {
        downcasted = int216(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(216, value);
        }
    }

    /**
     * @dev Returns the downcasted int208 from int256, reverting on
     * overflow (when the input is less than smallest int208 or
     * greater than largest int208).
     *
     * Counterpart to Solidity's `int208` operator.
     *
     * Requirements:
     *
     * - input must fit into 208 bits
     */
    function toInt208(int256 value) internal pure returns (int208 downcasted) {
        downcasted = int208(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(208, value);
        }
    }

    /**
     * @dev Returns the downcasted int200 from int256, reverting on
     * overflow (when the input is less than smallest int200 or
     * greater than largest int200).
     *
     * Counterpart to Solidity's `int200` operator.
     *
     * Requirements:
     *
     * - input must fit into 200 bits
     */
    function toInt200(int256 value) internal pure returns (int200 downcasted) {
        downcasted = int200(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(200, value);
        }
    }

    /**
     * @dev Returns the downcasted int192 from int256, reverting on
     * overflow (when the input is less than smallest int192 or
     * greater than largest int192).
     *
     * Counterpart to Solidity's `int192` operator.
     *
     * Requirements:
     *
     * - input must fit into 192 bits
     */
    function toInt192(int256 value) internal pure returns (int192 downcasted) {
        downcasted = int192(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(192, value);
        }
    }

    /**
     * @dev Returns the downcasted int184 from int256, reverting on
     * overflow (when the input is less than smallest int184 or
     * greater than largest int184).
     *
     * Counterpart to Solidity's `int184` operator.
     *
     * Requirements:
     *
     * - input must fit into 184 bits
     */
    function toInt184(int256 value) internal pure returns (int184 downcasted) {
        downcasted = int184(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(184, value);
        }
    }

    /**
     * @dev Returns the downcasted int176 from int256, reverting on
     * overflow (when the input is less than smallest int176 or
     * greater than largest int176).
     *
     * Counterpart to Solidity's `int176` operator.
     *
     * Requirements:
     *
     * - input must fit into 176 bits
     */
    function toInt176(int256 value) internal pure returns (int176 downcasted) {
        downcasted = int176(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(176, value);
        }
    }

    /**
     * @dev Returns the downcasted int168 from int256, reverting on
     * overflow (when the input is less than smallest int168 or
     * greater than largest int168).
     *
     * Counterpart to Solidity's `int168` operator.
     *
     * Requirements:
     *
     * - input must fit into 168 bits
     */
    function toInt168(int256 value) internal pure returns (int168 downcasted) {
        downcasted = int168(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(168, value);
        }
    }

    /**
     * @dev Returns the downcasted int160 from int256, reverting on
     * overflow (when the input is less than smallest int160 or
     * greater than largest int160).
     *
     * Counterpart to Solidity's `int160` operator.
     *
     * Requirements:
     *
     * - input must fit into 160 bits
     */
    function toInt160(int256 value) internal pure returns (int160 downcasted) {
        downcasted = int160(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(160, value);
        }
    }

    /**
     * @dev Returns the downcasted int152 from int256, reverting on
     * overflow (when the input is less than smallest int152 or
     * greater than largest int152).
     *
     * Counterpart to Solidity's `int152` operator.
     *
     * Requirements:
     *
     * - input must fit into 152 bits
     */
    function toInt152(int256 value) internal pure returns (int152 downcasted) {
        downcasted = int152(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(152, value);
        }
    }

    /**
     * @dev Returns the downcasted int144 from int256, reverting on
     * overflow (when the input is less than smallest int144 or
     * greater than largest int144).
     *
     * Counterpart to Solidity's `int144` operator.
     *
     * Requirements:
     *
     * - input must fit into 144 bits
     */
    function toInt144(int256 value) internal pure returns (int144 downcasted) {
        downcasted = int144(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(144, value);
        }
    }

    /**
     * @dev Returns the downcasted int136 from int256, reverting on
     * overflow (when the input is less than smallest int136 or
     * greater than largest int136).
     *
     * Counterpart to Solidity's `int136` operator.
     *
     * Requirements:
     *
     * - input must fit into 136 bits
     */
    function toInt136(int256 value) internal pure returns (int136 downcasted) {
        downcasted = int136(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(136, value);
        }
    }

    /**
     * @dev Returns the downcasted int128 from int256, reverting on
     * overflow (when the input is less than smallest int128 or
     * greater than largest int128).
     *
     * Counterpart to Solidity's `int128` operator.
     *
     * Requirements:
     *
     * - input must fit into 128 bits
     */
    function toInt128(int256 value) internal pure returns (int128 downcasted) {
        downcasted = int128(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(128, value);
        }
    }

    /**
     * @dev Returns the downcasted int120 from int256, reverting on
     * overflow (when the input is less than smallest int120 or
     * greater than largest int120).
     *
     * Counterpart to Solidity's `int120` operator.
     *
     * Requirements:
     *
     * - input must fit into 120 bits
     */
    function toInt120(int256 value) internal pure returns (int120 downcasted) {
        downcasted = int120(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(120, value);
        }
    }

    /**
     * @dev Returns the downcasted int112 from int256, reverting on
     * overflow (when the input is less than smallest int112 or
     * greater than largest int112).
     *
     * Counterpart to Solidity's `int112` operator.
     *
     * Requirements:
     *
     * - input must fit into 112 bits
     */
    function toInt112(int256 value) internal pure returns (int112 downcasted) {
        downcasted = int112(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(112, value);
        }
    }

    /**
     * @dev Returns the downcasted int104 from int256, reverting on
     * overflow (when the input is less than smallest int104 or
     * greater than largest int104).
     *
     * Counterpart to Solidity's `int104` operator.
     *
     * Requirements:
     *
     * - input must fit into 104 bits
     */
    function toInt104(int256 value) internal pure returns (int104 downcasted) {
        downcasted = int104(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(104, value);
        }
    }

    /**
     * @dev Returns the downcasted int96 from int256, reverting on
     * overflow (when the input is less than smallest int96 or
     * greater than largest int96).
     *
     * Counterpart to Solidity's `int96` operator.
     *
     * Requirements:
     *
     * - input must fit into 96 bits
     */
    function toInt96(int256 value) internal pure returns (int96 downcasted) {
        downcasted = int96(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(96, value);
        }
    }

    /**
     * @dev Returns the downcasted int88 from int256, reverting on
     * overflow (when the input is less than smallest int88 or
     * greater than largest int88).
     *
     * Counterpart to Solidity's `int88` operator.
     *
     * Requirements:
     *
     * - input must fit into 88 bits
     */
    function toInt88(int256 value) internal pure returns (int88 downcasted) {
        downcasted = int88(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(88, value);
        }
    }

    /**
     * @dev Returns the downcasted int80 from int256, reverting on
     * overflow (when the input is less than smallest int80 or
     * greater than largest int80).
     *
     * Counterpart to Solidity's `int80` operator.
     *
     * Requirements:
     *
     * - input must fit into 80 bits
     */
    function toInt80(int256 value) internal pure returns (int80 downcasted) {
        downcasted = int80(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(80, value);
        }
    }

    /**
     * @dev Returns the downcasted int72 from int256, reverting on
     * overflow (when the input is less than smallest int72 or
     * greater than largest int72).
     *
     * Counterpart to Solidity's `int72` operator.
     *
     * Requirements:
     *
     * - input must fit into 72 bits
     */
    function toInt72(int256 value) internal pure returns (int72 downcasted) {
        downcasted = int72(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(72, value);
        }
    }

    /**
     * @dev Returns the downcasted int64 from int256, reverting on
     * overflow (when the input is less than smallest int64 or
     * greater than largest int64).
     *
     * Counterpart to Solidity's `int64` operator.
     *
     * Requirements:
     *
     * - input must fit into 64 bits
     */
    function toInt64(int256 value) internal pure returns (int64 downcasted) {
        downcasted = int64(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(64, value);
        }
    }

    /**
     * @dev Returns the downcasted int56 from int256, reverting on
     * overflow (when the input is less than smallest int56 or
     * greater than largest int56).
     *
     * Counterpart to Solidity's `int56` operator.
     *
     * Requirements:
     *
     * - input must fit into 56 bits
     */
    function toInt56(int256 value) internal pure returns (int56 downcasted) {
        downcasted = int56(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(56, value);
        }
    }

    /**
     * @dev Returns the downcasted int48 from int256, reverting on
     * overflow (when the input is less than smallest int48 or
     * greater than largest int48).
     *
     * Counterpart to Solidity's `int48` operator.
     *
     * Requirements:
     *
     * - input must fit into 48 bits
     */
    function toInt48(int256 value) internal pure returns (int48 downcasted) {
        downcasted = int48(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(48, value);
        }
    }

    /**
     * @dev Returns the downcasted int40 from int256, reverting on
     * overflow (when the input is less than smallest int40 or
     * greater than largest int40).
     *
     * Counterpart to Solidity's `int40` operator.
     *
     * Requirements:
     *
     * - input must fit into 40 bits
     */
    function toInt40(int256 value) internal pure returns (int40 downcasted) {
        downcasted = int40(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(40, value);
        }
    }

    /**
     * @dev Returns the downcasted int32 from int256, reverting on
     * overflow (when the input is less than smallest int32 or
     * greater than largest int32).
     *
     * Counterpart to Solidity's `int32` operator.
     *
     * Requirements:
     *
     * - input must fit into 32 bits
     */
    function toInt32(int256 value) internal pure returns (int32 downcasted) {
        downcasted = int32(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(32, value);
        }
    }

    /**
     * @dev Returns the downcasted int24 from int256, reverting on
     * overflow (when the input is less than smallest int24 or
     * greater than largest int24).
     *
     * Counterpart to Solidity's `int24` operator.
     *
     * Requirements:
     *
     * - input must fit into 24 bits
     */
    function toInt24(int256 value) internal pure returns (int24 downcasted) {
        downcasted = int24(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(24, value);
        }
    }

    /**
     * @dev Returns the downcasted int16 from int256, reverting on
     * overflow (when the input is less than smallest int16 or
     * greater than largest int16).
     *
     * Counterpart to Solidity's `int16` operator.
     *
     * Requirements:
     *
     * - input must fit into 16 bits
     */
    function toInt16(int256 value) internal pure returns (int16 downcasted) {
        downcasted = int16(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(16, value);
        }
    }

    /**
     * @dev Returns the downcasted int8 from int256, reverting on
     * overflow (when the input is less than smallest int8 or
     * greater than largest int8).
     *
     * Counterpart to Solidity's `int8` operator.
     *
     * Requirements:
     *
     * - input must fit into 8 bits
     */
    function toInt8(int256 value) internal pure returns (int8 downcasted) {
        downcasted = int8(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(8, value);
        }
    }

    /**
     * @dev Converts an unsigned uint256 into a signed int256.
     *
     * Requirements:
     *
     * - input must be less than or equal to maxInt256.
     */
    function toInt256(uint256 value) internal pure returns (int256) {
        // Note: Unsafe cast below is okay because `type(int256).max` is guaranteed to be positive
        if (value > uint256(type(int256).max)) {
            revert SafeCastOverflowedUintToInt(value);
        }
        return int256(value);
    }

    /**
     * @dev Cast a boolean (false or true) to a uint256 (0 or 1) with no jump.
     */
    function toUint(bool b) internal pure returns (uint256 u) {
        assembly ("memory-safe") {
            u := iszero(iszero(b))
        }
    }
}


// File: lib/openzeppelin-contracts/contracts/utils/math/SignedMath.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (utils/math/SignedMath.sol)

pragma solidity ^0.8.20;

import {SafeCast} from "./SafeCast.sol";

/**
 * @dev Standard signed math utilities missing in the Solidity language.
 */
library SignedMath {
    /**
     * @dev Branchless ternary evaluation for `a ? b : c`. Gas costs are constant.
     *
     * IMPORTANT: This function may reduce bytecode size and consume less gas when used standalone.
     * However, the compiler may optimize Solidity ternary operations (i.e. `a ? b : c`) to only compute
     * one branch when needed, making this function more expensive.
     */
    function ternary(bool condition, int256 a, int256 b) internal pure returns (int256) {
        unchecked {
            // branchless ternary works because:
            // b ^ (a ^ b) == a
            // b ^ 0 == b
            return b ^ ((a ^ b) * int256(SafeCast.toUint(condition)));
        }
    }

    /**
     * @dev Returns the largest of two signed numbers.
     */
    function max(int256 a, int256 b) internal pure returns (int256) {
        return ternary(a > b, a, b);
    }

    /**
     * @dev Returns the smallest of two signed numbers.
     */
    function min(int256 a, int256 b) internal pure returns (int256) {
        return ternary(a < b, a, b);
    }

    /**
     * @dev Returns the average of two signed numbers without overflow.
     * The result is rounded towards zero.
     */
    function average(int256 a, int256 b) internal pure returns (int256) {
        // Formula from the book "Hacker's Delight"
        int256 x = (a & b) + ((a ^ b) >> 1);
        return x + (int256(uint256(x) >> 255) & (a ^ b));
    }

    /**
     * @dev Returns the absolute unsigned value of a signed value.
     */
    function abs(int256 n) internal pure returns (uint256) {
        unchecked {
            // Formula from the "Bit Twiddling Hacks" by Sean Eron Anderson.
            // Since `n` is a signed integer, the generated bytecode will use the SAR opcode to perform the right shift,
            // taking advantage of the most significant (or "sign" bit) in two's complement representation.
            // This opcode adds new most significant bits set to the value of the previous most significant bit. As a result,
            // the mask will either be `bytes32(0)` (if n is positive) or `~bytes32(0)` (if n is negative).
            int256 mask = n >> 255;

            // A `bytes32(0)` mask leaves the input unchanged, while a `~bytes32(0)` mask complements it.
            return uint256((n + mask) ^ mask);
        }
    }
}


// File: lib/l1-contracts/src/core/libraries/Errors.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {SlashRound} from "@aztec/core/libraries/SlashRoundLib.sol";
import {Timestamp, Slot, Epoch} from "@aztec/core/libraries/TimeLib.sol";

/**
 * @title Errors Library
 * @author Aztec Labs
 * @notice Library that contains errors used throughout the Aztec protocol
 * Errors are prefixed with the contract name to make it easy to identify where the error originated
 * when there are multiple contracts that could have thrown the error.
 *
 * Sigs are provided for easy reference, but don't trust; verify! run `forge inspect
 * src/core/libraries/Errors.sol:Errors errors`
 */
library Errors {
  // DEVNET related
  error DevNet__NoPruningAllowed(); // 0x6984c590
  error DevNet__InvalidProposer(address expected, address actual); // 0x11e6e6f7

  // Inbox
  error Inbox__Unauthorized(); // 0xe5336a6b
  error Inbox__ActorTooLarge(bytes32 actor); // 0xa776a06e
  error Inbox__VersionMismatch(uint256 expected, uint256 actual); // 0x47452014
  error Inbox__ContentTooLarge(bytes32 content); // 0x47452014
  error Inbox__SecretHashTooLarge(bytes32 secretHash); // 0xecde7e2c
  error Inbox__MustBuildBeforeConsume(); // 0xc4901999
  error Inbox__Ignition();

  // Outbox
  error Outbox__Unauthorized(); // 0x2c9490c2
  error Outbox__InvalidChainId(); // 0x577ec7c4
  error Outbox__VersionMismatch(uint256 expected, uint256 actual);
  error Outbox__NothingToConsume(bytes32 messageHash); // 0xfb4fb506
  error Outbox__IncompatibleEntryArguments(
    bytes32 messageHash,
    uint64 storedFee,
    uint64 feePassed,
    uint32 storedVersion,
    uint32 versionPassed,
    uint32 storedDeadline,
    uint32 deadlinePassed
  ); // 0x5e789f34
  error Outbox__RootAlreadySetAtBlock(uint256 l2BlockNumber); // 0x3eccfd3e
  error Outbox__InvalidRecipient(address expected, address actual); // 0x57aad581
  error Outbox__AlreadyNullified(uint256 l2BlockNumber, uint256 leafIndex); // 0xfd71c2d4
  error Outbox__NothingToConsumeAtBlock(uint256 l2BlockNumber); // 0xa4508f22
  error Outbox__BlockNotProven(uint256 l2BlockNumber); // 0x0e194a6d
  error Outbox__BlockAlreadyProven(uint256 l2BlockNumber);
  error Outbox__PathTooLong();
  error Outbox__LeafIndexOutOfBounds(uint256 leafIndex, uint256 pathLength);

  // Rollup
  error Rollup__InsufficientBondAmount(uint256 minimum, uint256 provided); // 0xa165f276
  error Rollup__InsufficientFundsInEscrow(uint256 required, uint256 available); // 0xa165f276
  error Rollup__InvalidArchive(bytes32 expected, bytes32 actual); // 0xb682a40e
  error Rollup__InvalidBlockNumber(uint256 expected, uint256 actual); // 0xe5edf847
  error Rollup__InvalidInHash(bytes32 expected, bytes32 actual); // 0xcd6f4233
  error Rollup__InvalidPreviousArchive(bytes32 expected, bytes32 actual); // 0xb682a40e
  error Rollup__InvalidProof(); // 0xa5b2ba17
  error Rollup__InvalidProposedArchive(bytes32 expected, bytes32 actual); // 0x32532e73
  error Rollup__InvalidTimestamp(Timestamp expected, Timestamp actual); // 0x3132e895
  error Rollup__InvalidAttestations();
  error Rollup__AttestationsAreValid();
  error Rollup__InvalidAttestationIndex();
  error Rollup__BlockAlreadyProven();
  error Rollup__BlockNotInPendingChain();
  error Rollup__InvalidBlobHash(bytes32 expected, bytes32 actual); // 0x13031e6a
  error Rollup__InvalidBlobProof(bytes32 blobHash); // 0x5ca17bef
  error Rollup__NoEpochToProve(); // 0xcbaa3951
  error Rollup__NonSequentialProving(); // 0x1e5be132
  error Rollup__NothingToPrune(); // 0x850defd3
  error Rollup__SlotAlreadyInChain(Slot lastSlot, Slot proposedSlot); // 0x83510bd0
  error Rollup__TimestampInFuture(Timestamp max, Timestamp actual); // 0x89f30690
  error Rollup__TimestampTooOld(); // 0x72ed9c81
  error Rollup__TryingToProveNonExistingBlock(); // 0x34ef4954
  error Rollup__UnavailableTxs(bytes32 txsHash); // 0x414906c3
  error Rollup__NonZeroDaFee(); // 0xd9c75f52
  error Rollup__InvalidBasisPointFee(uint256 basisPointFee); // 0x4292d136
  error Rollup__InvalidManaBaseFee(uint256 expected, uint256 actual); // 0x73b6d896
  error Rollup__StartAndEndNotSameEpoch(Epoch start, Epoch end); // 0xb64ec33e
  error Rollup__StartIsNotFirstBlockOfEpoch(); // 0x4ef11e0d
  error Rollup__StartIsNotBuildingOnProven(); // 0x4a59f42e
  error Rollup__TooManyBlocksInEpoch(uint256 expected, uint256 actual); // 0x7d5b1408
  error Rollup__NotPastDeadline(Epoch deadline, Epoch currentEpoch);
  error Rollup__PastDeadline(Epoch deadline, Epoch currentEpoch);
  error Rollup__ProverHaveAlreadySubmitted(address prover, Epoch epoch);
  error Rollup__InvalidManaTarget(uint256 minimum, uint256 provided);
  error Rollup__ManaLimitExceeded();
  error Rollup__RewardsNotClaimable();
  error Rollup__TooSoonToSetRewardsClaimable(uint256 earliestRewardsClaimableTimestamp, uint256 currentTimestamp);
  error Rollup__InvalidFirstEpochProof();
  error Rollup__InvalidCoinbase();
  error Rollup__UnavailableTempBlockLog(uint256 blockNumber, uint256 pendingBlockNumber, uint256 upperLimit);
  error Rollup__NoBlobsInBlock();

  // ProposedHeaderLib
  error HeaderLib__InvalidHeaderSize(uint256 expected, uint256 actual); // 0xf3ccb247
  error HeaderLib__InvalidSlotNumber(Slot expected, Slot actual); // 0x09ba91ff

  // MerkleLib
  error MerkleLib__InvalidRoot(bytes32 expected, bytes32 actual, bytes32 leaf, uint256 leafIndex); // 0x5f216bf1
  error MerkleLib__InvalidIndexForPathLength();

  // SampleLib
  error SampleLib__IndexOutOfBounds(uint256 requested, uint256 bound); // 0xa12fc559
  error SampleLib__SampleLargerThanIndex(uint256 sample, uint256 index); // 0xa11b0f79

  // Sequencer Selection (ValidatorSelection)
  error ValidatorSelection__EpochNotSetup(); // 0x10816cae
  error ValidatorSelection__InvalidProposer(address expected, address actual); // 0xa8843a68
  error ValidatorSelection__MissingProposerSignature(address proposer, uint256 index);
  error ValidatorSelection__InvalidDeposit(address attester, address proposer); // 0x533169bd
  error ValidatorSelection__InsufficientAttestations(uint256 minimumNeeded, uint256 provided); // 0xaf47297f
  error ValidatorSelection__InvalidCommitteeCommitment(bytes32 reconstructed, bytes32 expected); // 0xca8d5954
  error ValidatorSelection__InsufficientValidatorSetSize(uint256 actual, uint256 expected); // 0xf4f28e99
  error ValidatorSelection__ProposerIndexTooLarge(uint256 index);

  // Staking
  error Staking__AlreadyQueued(address _attester);
  error Staking__QueueEmpty();
  error Staking__DepositOutOfGas();
  error Staking__AlreadyActive(address attester); // 0x5e206fa4
  error Staking__QueueAlreadyFlushed(Epoch epoch); // 0x21148c78
  error Staking__AlreadyRegistered(address instance, address attester);
  error Staking__CannotSlashExitedStake(address); // 0x45bf4940
  error Staking__FailedToRemove(address); // 0xa7d7baab
  error Staking__InvalidDeposit(address attester, address proposer); // 0xf33fe8c6
  error Staking__InvalidRecipient(address); // 0x7e2f7f1c
  error Staking__InsufficientStake(uint256, uint256); // 0x903aee24
  error Staking__NoOneToSlash(address); // 0x7e2f7f1c
  error Staking__NotExiting(address); // 0xef566ee0
  error Staking__InitiateWithdrawNeeded(address);
  error Staking__NotSlasher(address, address); // 0x23a6f432
  error Staking__NotWithdrawer(address, address); // 0x8e668e5d
  error Staking__NothingToExit(address); // 0xd2aac9b6
  error Staking__WithdrawalNotUnlockedYet(Timestamp, Timestamp); // 0x88e1826c
  error Staking__WithdrawFailed(address); // 0x377422c1
  error Staking__OutOfBounds(uint256, uint256); // 0x4bea6597
  error Staking__NotRollup(address); // 0xf5509eb3
  error Staking__RollupAlreadyRegistered(address); // 0x108a39c8
  error Staking__InvalidRollupAddress(address); // 0xd876720e
  error Staking__NotCanonical(address); // 0x6244212e
  error Staking__InstanceDoesNotExist(address);
  error Staking__InsufficientPower(uint256, uint256);
  error Staking__AlreadyExiting(address);
  error Staking__FatalError(string);
  error Staking__NotOurProposal(uint256, address, address);
  error Staking__IncorrectGovProposer(uint256);
  error Staking__GovernanceAlreadySet();
  error Staking__InsufficientBootstrapValidators(uint256 queueSize, uint256 bootstrapFlushSize);
  error Staking__InvalidStakingQueueConfig();
  error Staking__InvalidNormalFlushSizeQuotient();

  // Fee Juice Portal
  error FeeJuicePortal__AlreadyInitialized(); // 0xc7a172fe
  error FeeJuicePortal__InvalidInitialization(); // 0xfd9b3208
  error FeeJuicePortal__Unauthorized(); // 0x67e3691e

  // Proof Commitment Escrow
  error ProofCommitmentEscrow__InsufficientBalance(uint256 balance, uint256 requested); // 0x09b8b789
  error ProofCommitmentEscrow__NotOwner(address caller); // 0x2ac332c1
  error ProofCommitmentEscrow__WithdrawRequestNotReady(uint256 current, Timestamp readyAt); // 0xb32ab8a7

  // FeeLib
  error FeeLib__InvalidFeeAssetPriceModifier(); // 0xf2fb32ad
  error FeeLib__AlreadyPreheated();

  // SignatureLib (duplicated)
  error SignatureLib__InvalidSignature(address, address); // 0xd9cbae6c

  error AttestationLib__InvalidDataSize(uint256, uint256);
  error AttestationLib__SignatureIndicesSizeMismatch(uint256, uint256);
  error AttestationLib__SignaturesOrAddressesSizeMismatch(uint256, uint256);
  error AttestationLib__SignersSizeMismatch(uint256, uint256);
  error AttestationLib__NotASignatureAtIndex(uint256 index);
  error AttestationLib__NotAnAddressAtIndex(uint256 index);

  // RewardBooster
  error RewardBooster__OnlyRollup(address caller);

  error RewardLib__InvalidSequencerBps();

  // TallySlashingProposer
  error TallySlashingProposer__InvalidSignature();
  error TallySlashingProposer__InvalidVoteLength(uint256 expected, uint256 actual);
  error TallySlashingProposer__RoundAlreadyExecuted(SlashRound round);
  error TallySlashingProposer__InvalidNumberOfCommittees(uint256 expected, uint256 actual);
  error TallySlashingProposer__RoundNotComplete(SlashRound round);
  error TallySlashingProposer__InvalidCommitteeSize(uint256 expected, uint256 actual);
  error TallySlashingProposer__InvalidCommitteeCommitment();
  error TallySlashingProposer__InvalidQuorumAndRoundSize(uint256 quorum, uint256 roundSize);
  error TallySlashingProposer__QuorumMustBeGreaterThanZero();
  error TallySlashingProposer__InvalidSlashAmounts(uint256[3] slashAmounts);
  error TallySlashingProposer__LifetimeMustBeGreaterThanExecutionDelay(uint256 lifetime, uint256 executionDelay);
  error TallySlashingProposer__LifetimeMustBeLessThanRoundabout(uint256 lifetime, uint256 roundabout);
  error TallySlashingProposer__RoundSizeInEpochsMustBeGreaterThanZero(uint256 roundSizeInEpochs);
  error TallySlashingProposer__RoundSizeTooLarge(uint256 roundSize, uint256 maxRoundSize);
  error TallySlashingProposer__CommitteeSizeMustBeGreaterThanZero(uint256 committeeSize);
  error TallySlashingProposer__SlashAmountTooLarge();
  error TallySlashingProposer__VoteAlreadyCastInCurrentSlot(Slot slot);
  error TallySlashingProposer__RoundOutOfRange(SlashRound round, SlashRound currentRound);
  error TallySlashingProposer__RoundSizeMustBeMultipleOfEpochDuration(uint256 roundSize, uint256 epochDuration);
  error TallySlashingProposer__VotingNotOpen(SlashRound currentRound);
  error TallySlashingProposer__SlashOffsetMustBeGreaterThanZero(uint256 slashOffset);
  error TallySlashingProposer__InvalidEpochIndex(uint256 epochIndex, uint256 roundSizeInEpochs);
  error TallySlashingProposer__VoteSizeTooBig(uint256 voteSize, uint256 maxSize);
  error TallySlashingProposer__VotesMustBeMultipleOf4(uint256 votes);

  // SlashPayloadLib
  error SlashPayload_ArraySizeMismatch(uint256 expected, uint256 actual);

  // OpenZeppelin dependencies

  // ECDSA
  error ECDSAInvalidSignature();
  error ECDSAInvalidSignatureLength(uint256 length);
  error ECDSAInvalidSignatureS(bytes32 s);

  // Ownable
  error OwnableUnauthorizedAccount(address account);
  error OwnableInvalidOwner(address owner);

  // Checkpoints
  error CheckpointUnorderedInsertion();

  // ERC20
  error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
  error ERC20InvalidSender(address sender);
  error ERC20InvalidReceiver(address receiver);
  error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
  error ERC20InvalidApprover(address approver);
  error ERC20InvalidSpender(address spender);

  // SafeCast
  error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value);
  error SafeCastOverflowedIntToUint(int256 value);
  error SafeCastOverflowedIntDowncast(uint8 bits, int256 value);
  error SafeCastOverflowedUintToInt(uint256 value);
}


// File: lib/l1-contracts/src/core/libraries/TimeLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

// solhint-disable-next-line no-unused-import
import {Timestamp, Slot, Epoch} from "@aztec/shared/libraries/TimeMath.sol";

import {SafeCast} from "@oz/utils/math/SafeCast.sol";

struct TimeStorage {
  uint128 genesisTime;
  uint32 slotDuration; // Number of seconds in a slot
  uint32 epochDuration; // Number of slots in an epoch
  /**
   * @notice Number of epochs after the end of a given epoch that proofs are still accepted. For example, a value of 1
   * means that after epoch n ends, the proofs must land *before* epoch n+1 ends. A value of 0 would mean that the
   * proofs for epoch n must land while the epoch is ongoing.
   */
  uint32 proofSubmissionEpochs;
}

library TimeLib {
  using SafeCast for uint256;

  bytes32 private constant TIME_STORAGE_POSITION = keccak256("aztec.time.storage");

  function initialize(
    uint256 _genesisTime,
    uint256 _slotDuration,
    uint256 _epochDuration,
    uint256 _proofSubmissionEpochs
  ) internal {
    TimeStorage storage store = getStorage();
    store.genesisTime = _genesisTime.toUint128();
    store.slotDuration = _slotDuration.toUint32();
    store.epochDuration = _epochDuration.toUint32();
    store.proofSubmissionEpochs = _proofSubmissionEpochs.toUint32();
  }

  function toTimestamp(Slot _a) internal view returns (Timestamp) {
    TimeStorage storage store = getStorage();
    return Timestamp.wrap(store.genesisTime) + Timestamp.wrap(Slot.unwrap(_a) * store.slotDuration);
  }

  function slotFromTimestamp(Timestamp _a) internal view returns (Slot) {
    TimeStorage storage store = getStorage();
    return Slot.wrap((Timestamp.unwrap(_a) - store.genesisTime) / store.slotDuration);
  }

  function toSlots(Epoch _a) internal view returns (Slot) {
    return Slot.wrap(Epoch.unwrap(_a) * getStorage().epochDuration);
  }

  function toTimestamp(Epoch _a) internal view returns (Timestamp) {
    return toTimestamp(toSlots(_a));
  }

  /**
   * @notice An epoch deadline is the epoch at which:
   *         - proofs are no longer accepted
   *         - which we may prune if no proof has landed
   *         - rewards may be claimed
   *
   * @param _a - The epoch to compute the deadline for
   *
   * @return The computed epoch
   */
  function toDeadlineEpoch(Epoch _a) internal view returns (Epoch) {
    TimeStorage storage store = getStorage();
    // We add one to the proof submission epochs to account for the current epoch.
    // This is because toSlots will return the first slot of the epoch, and in the event
    // that proofSubmissionEpochs is 0, we would wait until the end of the current epoch.
    return _a + Epoch.wrap(store.proofSubmissionEpochs + 1);
  }

  /**
   * @notice Calculates the maximum number of blocks that can be pruned from the pending chain
   * @dev The maximum prunable blocks is determined by:
   *      - epochDuration: number of slots in an epoch
   *      - proofSubmissionEpochs: number of epochs allowed for proof submission
   *
   *      The formula is: epochDuration * (proofSubmissionEpochs + 1)
   *
   *      The +1 accounts for blocks in the current epoch, ensuring they are included
   *      in the prunable window along with blocks from previous epochs within the
   *      proof submission window.
   *
   *      This value is used to:
   *      1. Size the circular storage buffer (roundaboutSize = maxPrunableBlocks + 1)
   *      2. Determine when blocks become stale and can be overwritten
   *
   * @return The maximum number of blocks that can be pruned.
   */
  function maxPrunableBlocks() internal view returns (uint256) {
    TimeStorage storage store = getStorage();
    return uint256(store.epochDuration) * (uint256(store.proofSubmissionEpochs) + 1);
  }

  /**
   * @notice Checks if proofs are being accepted for epoch _a during epoch _b
   *
   * @param _a - The epoch that may be accepting proofs
   * @param _b - The epoch we would like to submit the proof for
   *
   * @return True if proofs would be accepted for epoch _a during epoch _b
   */
  function isAcceptingProofsAtEpoch(Epoch _a, Epoch _b) internal view returns (bool) {
    return _b < toDeadlineEpoch(_a);
  }

  function epochFromTimestamp(Timestamp _a) internal view returns (Epoch) {
    TimeStorage storage store = getStorage();

    return Epoch.wrap((Timestamp.unwrap(_a) - store.genesisTime) / (store.epochDuration * store.slotDuration));
  }

  function epochFromSlot(Slot _a) internal view returns (Epoch) {
    return Epoch.wrap(Slot.unwrap(_a) / getStorage().epochDuration);
  }

  function getEpochDurationInSeconds() internal view returns (uint256) {
    TimeStorage storage store = getStorage();
    return store.epochDuration * store.slotDuration;
  }

  function getStorage() internal pure returns (TimeStorage storage storageStruct) {
    bytes32 position = TIME_STORAGE_POSITION;
    assembly {
      storageStruct.slot := position
    }
  }
}


// File: lib/l1-contracts/src/core/libraries/rollup/STFLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {RollupStore, IRollupCore, GenesisState} from "@aztec/core/interfaces/IRollup.sol";
import {
  CompressedTempBlockLog,
  TempBlockLog,
  CompressedTempBlockLogLib
} from "@aztec/core/libraries/compressed-data/BlockLog.sol";
import {CompressedFeeHeader, FeeHeaderLib} from "@aztec/core/libraries/compressed-data/fees/FeeStructs.sol";
import {ChainTipsLib, CompressedChainTips} from "@aztec/core/libraries/compressed-data/Tips.sol";
import {Errors} from "@aztec/core/libraries/Errors.sol";
import {Timestamp, Slot, Epoch, TimeLib} from "@aztec/core/libraries/TimeLib.sol";
import {CompressedSlot, CompressedTimeMath} from "@aztec/shared/libraries/CompressedTimeMath.sol";

/**
 * @title STFLib - State Transition Function Library
 * @author Aztec Labs
 * @notice Core library responsible for managing the rollup state transition function and block storage.
 *
 * @dev This library implements the essential state management functionality for the Aztec rollup, including:
 *      - Archive root storage indexed by block number for permanent state history
 *      - Circular storage for temporary block logs
 *      - Block pruning mechanism to remove unproven blocks after proof submission window expires
 *      - Namespaced storage pattern following EIP-7201 for secure storage isolation
 *
 *      Storage Architecture:
 *      - Uses EIP-7201 namespaced storage
 *      - Archives mapping: permanent storage of proven block archive roots
 *      - TempBlockLogs: circular buffer storing temporary block data (gets overwritten after N blocks)
 *      - Tips: tracks both pending (latest proposed) and proven (latest with valid proof) block numbers
 *
 *      Circular Storage ("Roundabout") Pattern:
 *      - The temporary block logs use a circular storage pattern where blocks are stored at index (blockNumber %
 *        roundaboutSize).
 *        This reuses storage slots for old blocks that have been proven or pruned.
 *        The roundabout size is calculated as maxPrunableBlocks() + 1 to ensure at least the last proven block
 *        remains accessible even after pruning operations. This saves gas costs by minimizing storage writes to fresh
 *        slots.
 *
 *      Pruning Mechanism:
 *      - Blocks become eligible for pruning when their proof submission window expires. The proof submission
 *        window is defined as a configurable number of epochs after the epoch containing the block.
 *        When pruning occurs, all unproven blocks are removed from the pending chain, and the chain
 *        resumes from the last proven block.
 *      - Rationale for pruning is that an epoch may contain a block that provers cannot prove. Pruning allows us to
 *        trade a large reorg for chain liveness, by removing potential unprovable blocks so we can continue.
 *      - A prover may not be able to prove a block if the transaction data for that block is not available. Transaction
 *        data is NOT posted to DA since transactions (along with their ClientIVC proofs) are big, and it would be too
 *        costly to submit everything to blocks. So we count on the committee to attest to the availability of that
 *        data, but if for some reason the data does not reach provers via p2p, then provers will not be able to prove.
 *
 *      Security Considerations:
 *      - Archive roots provide immutable history of proven state transitions
 *      - Circular storage saves gas while maintaining necessary data
 *      - Proof submission windows ensure liveness by preventing indefinite stalling
 *      - EIP-7201 namespaced storage prevents accidental storage collisions with other contracts
 *
 * @dev TempBlockLog Structure
 *
 *      The TempBlockLog struct represents temporary block data stored in the circular buffer
 *      until blocks overwritten. It contains:
 *
 *      Fields:
 *      - headerHash: Hash of the complete block header containing all block metadata
 *      - blobCommitmentsHash: Hash of all blob commitments used for data availability verification
 *      - attestationsHash: Hash of committee member attestations validating the block
 *      - payloadDigest: Digest of the proposal payload that committee members attested to
 *      - slotNumber: The specific slot when this block was proposed (determines epoch assignment)
 *      - feeHeader: Compressed fee information including base fees and mana pricing
 *
 *      Storage Optimization:
 *      The struct is stored in compressed format (CompressedTempBlockLog) to minimize gas costs.
 *      Compression primarily affects the slotNumber (reduced from 256-bit to smaller representation)
 *      and feeHeader (packed fee components). Other fields remain as 32-byte hashes.
 */
library STFLib {
  using TimeLib for Slot;
  using TimeLib for Epoch;
  using TimeLib for Timestamp;
  using CompressedTimeMath for CompressedSlot;
  using ChainTipsLib for CompressedChainTips;
  using CompressedTempBlockLogLib for CompressedTempBlockLog;
  using CompressedTempBlockLogLib for TempBlockLog;
  using CompressedTimeMath for Slot;
  using CompressedTimeMath for CompressedSlot;
  using FeeHeaderLib for CompressedFeeHeader;

  // @note  This is also used in the cheatcodes, so if updating, please also update the cheatcode.
  bytes32 private constant STF_STORAGE_POSITION = keccak256("aztec.stf.storage");

  /**
   * @notice Initializes the rollup state with genesis configuration
   * @dev Sets up the initial state of the rollup including verification keys and the genesis archive root.
   *      This function should only be called once during rollup deployment.
   *
   * @param _genesisState The initial state configuration containing:
   *        - vkTreeRoot: Root of the verification key tree for circuit verification
   *        - protocolContractTreeRoot: Root containing protocol contract addresses and configurations
   *        - genesisArchiveRoot: Initial archive root representing the genesis state
   */
  function initialize(GenesisState memory _genesisState) internal {
    RollupStore storage rollupStore = STFLib.getStorage();

    rollupStore.config.vkTreeRoot = _genesisState.vkTreeRoot;
    rollupStore.config.protocolContractTreeRoot = _genesisState.protocolContractTreeRoot;

    rollupStore.archives[0] = _genesisState.genesisArchiveRoot;
  }

  /**
   * @notice Stores a temporary block log in the circular storage buffer
   * @dev Compresses and stores block data at the appropriate index in the circular buffer.
   *      The storage index is calculated as (pending block % roundaboutSize) to implement
   *      the circular storage pattern.
   *      Don't need to check if storage is stale as always writing to freshest.
   *
   * @param _tempBlockLog The temporary block log containing header hash, attestations,
   *        blob commitments, payload digest, slot number, and fee information
   */
  function addTempBlockLog(TempBlockLog memory _tempBlockLog) internal {
    uint256 blockNumber = STFLib.getStorage().tips.getPendingBlockNumber();
    uint256 size = roundaboutSize();
    getStorage().tempBlockLogs[blockNumber % size] = _tempBlockLog.compress();
  }

  /**
   * @notice Removes unproven blocks from the pending chain when proof submission window expires
   * @dev This function implements the pruning mechanism that maintains rollup liveness by removing
   *      blocks that cannot be proven within the configured time window. When called:
   *
   *      1. Identifies the gap between pending and proven block numbers
   *      2. Resets the pending chain tip to match the last proven block
   *      3. Effectively removes all unproven blocks from the pending chain
   *
   *      The pruning does not delete block data from storage but makes it inaccessible by
   *      updating the chain tips.
   *
   *      Pruning should only occur when the proof submission window has expired for pending
   *      blocks, which is validated by the calling function (typically through canPruneAtTime).
   *
   *      Emits PrunedPending event with the proven and previously pending block numbers.
   */
  function prune() internal {
    RollupStore storage rollupStore = STFLib.getStorage();
    CompressedChainTips tips = rollupStore.tips;
    uint256 pending = tips.getPendingBlockNumber();

    // @note  We are not deleting the blocks, but we are "winding back" the pendingTip to the last block that was
    //        proven.
    //        We can do because any new block proposed will overwrite a previous block in the block log,
    //        so no values should "survive".
    //        People must therefore read the chain using the pendingTip as a boundary.
    uint256 proven = tips.getProvenBlockNumber();
    rollupStore.tips = tips.updatePendingBlockNumber(proven);

    emit IRollupCore.PrunedPending(proven, pending);
  }

  /**
   * @notice Calculates the size of the circular storage buffer for temporary block logs
   * @dev The roundabout size determines how many blocks can be stored in the circular buffer
   *      before older entries are overwritten. The size is calculated as:
   *
   *      roundaboutSize = maxPrunableBlocks() + 1
   *
   *      Where maxPrunableBlocks() = epochDuration * (proofSubmissionEpochs + 1)
   *
   *      This ensures that:
   *      - All blocks within the proof submission window remain accessible
   *      - At least the last proven block is available as a trusted anchor
   *
   * @return The number of slots in the circular storage buffer
   */
  function roundaboutSize() internal view returns (uint256) {
    // Must be ensured to contain at least the last proven block even after a prune.
    return TimeLib.maxPrunableBlocks() + 1;
  }

  /**
   * @notice Returns a storage reference to a compressed temporary block log
   * @dev Provides direct access to the compressed block log in storage without decompression.
   *      Reverts if the block number is stale (no longer accessible in circular storage) or if
   *      the block have not happened yet.
   *
   * @dev A temporary block log is stale if it can no longer be accessed in the circular storage buffer.
   *      The staleness is determined by the relationship between the block number, current pending
   *      block, and the buffer size.
   *
   *      Example with roundabout size 5 and pending block 7:
   *      Circular buffer state: [block5, block6, block7, block3, block4]
   *
   *      A block is available if:
   *      - blockNumber <= pending  (it is not in the future)
   *      - pending < blockNumber + size (the override is in the future)
   *      Together as a span:
   *      - blockNumber <= pending < blockNumber + size
   *
   *      For example, block 2 is unavailable since the override has happened:
   *      - 2 <= 7 (true) && 7 < 2 + 5 (false)
   *      But block 3 is available as it in the past, but not overridden yet
   *      - 3 <= 7 (true) && 7 < 3 + 5 (true)
   *
   *      This ensures that only blocks within the current "window" of the circular buffer
   *      are considered valid and accessible.
   *
   * @param _blockNumber The block number to get the storage reference for
   * @return A storage reference to the compressed temporary block log
   */
  function getStorageTempBlockLog(uint256 _blockNumber) internal view returns (CompressedTempBlockLog storage) {
    uint256 pending = getStorage().tips.getPendingBlockNumber();
    uint256 size = roundaboutSize();

    uint256 upperLimit = _blockNumber + size;
    bool available = _blockNumber <= pending && pending < upperLimit;
    require(available, Errors.Rollup__UnavailableTempBlockLog(_blockNumber, pending, upperLimit));

    return getStorage().tempBlockLogs[_blockNumber % size];
  }

  /**
   * @notice Retrieves and decompresses a temporary block log from circular storage
   * @dev Fetches the compressed block log from the circular buffer and decompresses it.
   *      Reverts if the block number is stale and no longer accessible.
   * @param _blockNumber The block number to retrieve the log for
   * @return The decompressed temporary block log containing all block metadata
   */
  function getTempBlockLog(uint256 _blockNumber) internal view returns (TempBlockLog memory) {
    return getStorageTempBlockLog(_blockNumber).decompress();
  }

  /**
   * @notice Retrieves the header hash for a specific block number
   * @dev Gas-efficient accessor that returns only the header hash without decompressing
   *      the entire block log. Reverts if the block number is stale.
   * @param _blockNumber The block number to get the header hash for
   * @return The header hash of the specified block
   */
  function getHeaderHash(uint256 _blockNumber) internal view returns (bytes32) {
    return getStorageTempBlockLog(_blockNumber).headerHash;
  }

  /**
   * @notice Retrieves the compressed fee header for a specific block number
   * @dev Returns the fee information including base fee components and mana costs.
   *      The data remains in compressed format for gas efficiency. Reverts if the block is stale.
   * @param _blockNumber The block number to get the fee header for
   * @return The compressed fee header containing fee-related data
   */
  function getFeeHeader(uint256 _blockNumber) internal view returns (CompressedFeeHeader) {
    return getStorageTempBlockLog(_blockNumber).feeHeader;
  }

  /**
   * @notice Retrieves the blob commitments hash for a specific block number
   * @dev Returns the hash of all blob commitments for the block, used for data availability
   *      verification. Reverts if the block number is stale.
   * @param _blockNumber The block number to get the blob commitments hash for
   * @return The hash of blob commitments for the specified block
   */
  function getBlobCommitmentsHash(uint256 _blockNumber) internal view returns (bytes32) {
    return getStorageTempBlockLog(_blockNumber).blobCommitmentsHash;
  }

  /**
   * @notice Retrieves the slot number for a specific block number
   * @dev Returns the decompressed slot number indicating when the block was proposed.
   *      Reverts if the block number is stale.
   * @param _blockNumber The block number to get the slot number for
   * @return The slot number when the block was proposed
   */
  function getSlotNumber(uint256 _blockNumber) internal view returns (Slot) {
    return getStorageTempBlockLog(_blockNumber).slotNumber.decompress();
  }

  /**
   * @notice Gets the effective pending block number based on pruning eligibility
   * @dev Returns either the pending block number or proven block number depending on
   *      whether pruning is allowed at the given timestamp. This is used to determine
   *      the effective chain tip for operations that should respect pruning windows.
   *
   *      If pruning is allowed: returns proven block number (chain should be pruned)
   *      If pruning is not allowed: returns pending block number (normal operation)
   * @param _timestamp The timestamp to evaluate pruning eligibility against
   * @return The effective block number that should be considered as the chain tip
   */
  function getEffectivePendingBlockNumber(Timestamp _timestamp) internal view returns (uint256) {
    RollupStore storage rollupStore = STFLib.getStorage();
    CompressedChainTips tips = rollupStore.tips;
    return STFLib.canPruneAtTime(_timestamp) ? tips.getProvenBlockNumber() : tips.getPendingBlockNumber();
  }

  /**
   * @notice Determines which epoch a block belongs to
   * @dev Calculates the epoch for a given block number by retrieving the block's slot
   *      and converting it to an epoch. Reverts if the block number exceeds the pending tip.
   * @param _blockNumber The block number to get the epoch for
   * @return The epoch containing the specified block
   */
  function getEpochForBlock(uint256 _blockNumber) internal view returns (Epoch) {
    RollupStore storage rollupStore = STFLib.getStorage();
    require(
      _blockNumber <= rollupStore.tips.getPendingBlockNumber(),
      Errors.Rollup__InvalidBlockNumber(rollupStore.tips.getPendingBlockNumber(), _blockNumber)
    );
    return getSlotNumber(_blockNumber).epochFromSlot();
  }

  /**
   * @notice Determines if the chain can be pruned at a given timestamp
   * @dev Checks whether the proof submission window has expired for the oldest pending blocks.
   *      Pruning is allowed when:
   *
   *      1. There are unproven blocks (pending > proven)
   *      2. The oldest pending epoch is no longer accepting proofs at the epoch at _ts
   *
   *      The proof submission window is defined by the aztecProofSubmissionEpochs configuration,
   *      which specifies how many epochs after an epoch ends that proofs are still accepted.
   *
   *      Example timeline:
   *      - Block proposed in epoch N
   *      - Proof submission window = 1 epochs
   *      - Proof deadline epoch = N + Proof submission window + 1
   *          The deadline is the point in time where it is no longer acceptable, (if you touch the line you die)
   *      - If epoch(_ts) >= epoch N + Proof submission window + 1, pruning is allowed
   *
   *      This mechanism ensures rollup liveness by preventing indefinite stalling on unprovable blocks (e.g due to
   *      the committee failing to disseminate the data) while providing sufficient time for proof generation and
   *      submission.
   *
   * @param _ts The current timestamp to check against
   * @return True if pruning is allowed at the given timestamp, false otherwise
   */
  function canPruneAtTime(Timestamp _ts) internal view returns (bool) {
    RollupStore storage rollupStore = STFLib.getStorage();

    CompressedChainTips tips = rollupStore.tips;

    if (tips.getPendingBlockNumber() == tips.getProvenBlockNumber()) {
      return false;
    }

    Epoch oldestPendingEpoch = getEpochForBlock(tips.getProvenBlockNumber() + 1);
    Epoch currentEpoch = _ts.epochFromTimestamp();

    return !oldestPendingEpoch.isAcceptingProofsAtEpoch(currentEpoch);
  }

  /**
   * @notice Retrieves the namespaced storage for the STFLib using EIP-7201 pattern
   * @dev Uses inline assembly to access storage at a specific slot calculated from the
   *      keccak256 hash of "aztec.stf.storage". This ensures storage isolation and
   *      prevents collisions with other contracts or libraries.
   *
   *      The storage contains:
   *      - Chain tips (pending and proven block numbers)
   *      - Archives mapping (permanent block archive storage)
   *      - TempBlockLogs mapping (circular buffer for temporary block data)
   *      - Rollup configuration
   * @return storageStruct A storage pointer to the RollupStore struct
   */
  function getStorage() internal pure returns (RollupStore storage storageStruct) {
    bytes32 position = STF_STORAGE_POSITION;
    assembly {
      storageStruct.slot := position
    }
  }
}


// File: lib/l1-contracts/src/core/libraries/crypto/Hash.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {DataStructures} from "@aztec/core/libraries/DataStructures.sol";

/**
 * @title Hash library
 * @author Aztec Labs
 * @notice Library that contains helper functions to compute hashes for data structures and convert to field elements
 * Using sha256 as the hash function since it hits a good balance between gas cost and circuit size.
 */
library Hash {
  /**
   * @notice Computes the sha256 hash of the L1 to L2 message and converts it to a field element
   * @param _message - The L1 to L2 message to hash
   * @return The hash of the provided message as a field element
   */
  function sha256ToField(DataStructures.L1ToL2Msg memory _message) internal pure returns (bytes32) {
    return sha256ToField(
      abi.encode(_message.sender, _message.recipient, _message.content, _message.secretHash, _message.index)
    );
  }

  /**
   * @notice Computes the sha256 hash of the L2 to L1 message and converts it to a field element
   * @param _message - The L2 to L1 message to hash
   * @return The hash of the provided message as a field element
   */
  function sha256ToField(DataStructures.L2ToL1Msg memory _message) internal pure returns (bytes32) {
    return sha256ToField(
      abi.encodePacked(
        _message.sender.actor,
        _message.sender.version,
        _message.recipient.actor,
        _message.recipient.chainId,
        _message.content
      )
    );
  }

  /**
   * @notice Computes the sha256 hash of the provided data and converts it to a field element
   * @dev Truncating one byte to convert the hash to a field element. We prepend a byte rather than cast
   * bytes31(bytes32) to match Noir's to_be_bytes.
   * @param _data - The bytes to hash
   * @return The hash of the provided data as a field element
   */
  function sha256ToField(bytes memory _data) internal pure returns (bytes32) {
    return bytes32(bytes.concat(new bytes(1), bytes31(sha256(_data))));
  }
}


// File: lib/l1-contracts/src/governance/Governance.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {
  IGovernance,
  Proposal,
  ProposalState,
  Configuration,
  ProposeWithLockConfiguration,
  Withdrawal
} from "@aztec/governance/interfaces/IGovernance.sol";
import {IPayload} from "@aztec/governance/interfaces/IPayload.sol";
import {Checkpoints, CheckpointedUintLib} from "@aztec/governance/libraries/CheckpointedUintLib.sol";
import {Ballot, CompressedBallot, BallotLib} from "@aztec/governance/libraries/compressed-data/Ballot.sol";
import {
  CompressedConfiguration,
  CompressedConfigurationLib
} from "@aztec/governance/libraries/compressed-data/Configuration.sol";
import {CompressedProposal, CompressedProposalLib} from "@aztec/governance/libraries/compressed-data/Proposal.sol";
import {ConfigurationLib} from "@aztec/governance/libraries/ConfigurationLib.sol";
import {Errors} from "@aztec/governance/libraries/Errors.sol";
import {ProposalLib, VoteTabulationReturn} from "@aztec/governance/libraries/ProposalLib.sol";
import {Timestamp} from "@aztec/shared/libraries/TimeMath.sol";
import {IERC20} from "@oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "@oz/token/ERC20/utils/SafeERC20.sol";

/**
 * @dev a whitelist, controlling who may have power in the governance contract.
 * That is, an address must be an approved beneficiary to receive power via `deposit`.
 *
 * The caveat is that the owner of the contract may open the floodgates, allowing all addresses to hold power.
 * This is currently a "one-way-valve", since if it were reopened after being shut,
 * the contract is in an odd state where entities are holding power, but not allowed to receive more;
 * the whitelist is enabled, but does not reflect the functional entities in the system.
 * As an aside, it is unlikely that in the event Governance were opened up to all addresses,
 * those same addresses would subsequently vote to close it again.
 *
 * In practice, it is expected that the only authorized beneficiary will be the GSE.
 * This is because all rollup instances deposit their stake into the GSE, which in turn deposits it into the governance
 * contract. In turn, it is the GSE that votes on proposals.
 */
struct DepositControl {
  mapping(address beneficiary => bool allowed) isAllowed;
  bool allBeneficiariesAllowed;
}

/**
 * @title Governance
 * @author Aztec Labs
 * @notice A contract that implements governance logic for proposal creation, voting, and execution.
 *         Uses a snapshot-based voting model with partial vote support to enable aggregated voting.
 *
 *         Partial vote support: Allows voters to split their voting power across multiple proposals
 *         or options, rather than using all their votes on a single choice.
 *
 *         Aggregated voting: The contract collects and sums votes from multiple sources or over time,
 *         combining them to determine the final outcome of each proposal.
 *
 * @dev KEY CONCEPTS:
 *
 * **Power**: Funds received via `deposit` are held by Governance and tracked 1:1 as "power" for the beneficiary.
 *
 * **Proposals**: Payloads containing actions to be executed by governance (excluding calls to the governance ASSET).
 *
 * **Deposit Control**: A whitelist system controlling who can hold power in governance.
 * - Initially restricted to approved beneficiaries (expected to be only the GSE)
 * - Can be opened to all addresses via `openFloodgates` (one-way valve)
 * - The GSE aggregates stake from all rollup instances and votes on their behalf
 *
 * **Voting Power**: Based on checkpointed deposit history, calculated per proposal.
 *
 * @dev PROPOSAL LIFECYCLE: (see `getProposalState` for details)
 *
 * The current state of a proposal may be retrieved via `getProposalState`.
 *
 * 1. **Pending** (creation → creation + votingDelay)
 *    - Proposal exists but voting hasn't started
 *    - Power snapshot taken at end of this phase
 *
 * 2. **Active** (pendingThrough + 1 → pendingThrough + votingDuration)
 *    - Voting open using power from snapshot
 *    - Multiple partial votes allowed per user
 *
 * 3. **Vote Evaluation** → Rejected if criteria not met:
 *    - Minimum quorum (% of total power)
 *    - Required yea margin (yea votes minus nay votes)
 *
 * 4. **Queued** (activeThrough + 1 → activeThrough + executionDelay)
 *    - Timelock period before execution
 *
 * 5. **Executable** (queuedThrough + 1 → queuedThrough + gracePeriod)
 *    - Anyone can execute during this window
 *
 * 6. **Other States**:
 *    - Executed: Successfully completed
 *    - Expired: Execution window passed
 *    - Rejected: Failed voting criteria
 *    - Droppable: Proposer changed
 *    - Dropped: Proposal dropped via `dropProposal`
 *
 * @dev USER FLOW:
 *
 * 1. **Deposit**: Transfer ASSET to governance for voting power
 *    - Only whitelisted beneficiaries can hold power
 *    - Power is checkpointed for historical lookups
 *
 * 2. **Vote**: Use power from proposal's snapshot timestamp
 *    - Support partial voting (multiple votes allowed, both yea and nay)
 *    - A user's total votes may not exceed their power snapshot for the proposal
 *
 * 3. **Withdraw**: Two-step process with delay
 *    - Initiate: Reduce power
 *    - Finalize: Transfer funds after delay expires
 *    - Standard delay: votingDelay/5 + votingDuration + executionDelay
 *
 * @dev PROPOSAL CREATION:
 *
 * - **Standard**: `governanceProposer` calls `propose`
 * - **Emergency**: Anyone with sufficient power calls `proposeWithLock`
 *   - Requires withdrawing `lockAmount` of power with a finalization delay of `lockDelay`
 *   - Proposal proposer becomes governance itself (cannot be dropped)
 *
 * @dev CONFIGURATION:
 * All timing parameters are controlled by the governance configuration:
 * - votingDelay: Buffer before voting opens
 * - votingDuration: Voting period length
 * - executionDelay: Timelock after voting before the proposal may be executed
 * - gracePeriod: Execution window
 * - minimumVotes: Absolute minimum voting power in system
 * - quorum: Minimum acceptable participation as a percentage of total power
 * - requiredYeaMargin: Required difference between yea and nay votes as a percentage of the votes cast
 * - lockAmount: The amount of power to withdraw when `proposeWithLock` is called
 * - lockDelay: The delay before a withdrawal created by `proposeWithLock` is finalized
 */
contract Governance is IGovernance {
  using SafeERC20 for IERC20;
  using ProposalLib for CompressedProposal;
  using CheckpointedUintLib for Checkpoints.Trace224;
  using ConfigurationLib for Configuration;
  using ConfigurationLib for CompressedConfiguration;
  using CompressedConfigurationLib for CompressedConfiguration;
  using CompressedProposalLib for CompressedProposal;
  using BallotLib for CompressedBallot;

  IERC20 public immutable ASSET;

  /**
   * @dev The address that is allowed to `propose` new proposals.
   *
   * This address can only be updated by the governance itself through a proposal.
   */
  address public governanceProposer;

  /**
   * @dev The whitelist of beneficiaries that are allowed to hold power via `deposit`,
   * and the flag to allow all beneficiaries to hold power.
   */
  DepositControl internal depositControl;

  /**
   * @dev The proposals that have been made.
   *
   * The proposal ID is the current count of proposals (see `proposalCount`).
   * New proposals are created by calling `_propose`, via `propose` or `proposeWithLock`.
   * The storage of a proposal may be modified by calling `vote`, `execute`, or `dropProposal`.
   */
  mapping(uint256 proposalId => CompressedProposal proposal) internal proposals;

  /**
   * @dev The ballots that have been cast for each proposal.
   *
   * `CompressedBallot`s contain a compressed `yea` and `nay` count (uint128 each packed into uint256),
   * which are the number of votes for and against the proposal.
   * `ballots` is only updated during `vote`.
   */
  mapping(uint256 proposalId => mapping(address user => CompressedBallot ballot)) internal ballots;

  /**
   * @dev Checkpointed deposit amounts for an address.
   *
   * `users` is only updated during `deposit`, `initiateWithdraw`, and `proposeWithLock`.
   */
  mapping(address userAddress => Checkpoints.Trace224 user) internal users;

  /**
   * @dev Withdrawals that have been initiated.
   *
   * `withdrawals` is only updated during `initiateWithdraw`, `proposeWithLock`, and `finalizeWithdraw`.
   */
  mapping(uint256 withdrawalId => Withdrawal withdrawal) internal withdrawals;

  /**
   * @dev The configuration of the governance contract.
   *
   * `configuration` is set in the constructor, and is only updated during `updateConfiguration`,
   * which must be done via a proposal.
   */
  CompressedConfiguration internal configuration;

  /**
   * @dev The total power of the governance contract.
   *
   * `total` is only updated during `deposit`, `initiateWithdraw`, and `proposeWithLock`.
   */
  Checkpoints.Trace224 internal total;

  /**
   * @dev The count of proposals that have been made.
   *
   * `proposalCount` is only updated during `_propose`.
   */
  uint256 public proposalCount;

  /**
   * @dev The count of withdrawals that have been initiated.
   *
   * `withdrawalCount` is only updated during `initiateWithdraw` and `proposeWithLock`.
   */
  uint256 public withdrawalCount;

  /**
   * @dev Modifier to ensure that the caller is the governance contract itself.
   *
   * The caller will only be the governance itself if executed via a proposal.
   */
  modifier onlySelf() {
    require(msg.sender == address(this), Errors.Governance__CallerNotSelf(msg.sender, address(this)));
    _;
  }

  /**
   * @dev Modifier to ensure that the beneficiary is allowed to hold power in Governance.
   */
  modifier isDepositAllowed(address _beneficiary) {
    require(msg.sender != address(this), Errors.Governance__CallerCannotBeSelf());
    require(
      depositControl.allBeneficiariesAllowed || depositControl.isAllowed[_beneficiary],
      Errors.Governance__DepositNotAllowed()
    );

    _;
  }

  /**
   * @dev the initial _beneficiary is expected to be the GSE or address(0) for anyone
   */
  constructor(IERC20 _asset, address _governanceProposer, address _beneficiary, Configuration memory _configuration) {
    ASSET = _asset;
    governanceProposer = _governanceProposer;

    _configuration.assertValid();
    configuration = CompressedConfigurationLib.compress(_configuration);

    if (_beneficiary == address(0)) {
      depositControl.allBeneficiariesAllowed = true;
      emit FloodGatesOpened();
    } else {
      depositControl.allBeneficiariesAllowed = false;
      depositControl.isAllowed[_beneficiary] = true;
      emit BeneficiaryAdded(_beneficiary);
    }
  }

  /**
   * @notice Add a beneficiary to the whitelist.
   * @dev The beneficiary may hold power in the governance contract after this call.
   * only callable by the governance contract itself.
   *
   * @param _beneficiary The address to add to the whitelist.
   */
  function addBeneficiary(address _beneficiary) external override(IGovernance) onlySelf {
    depositControl.isAllowed[_beneficiary] = true;
    emit BeneficiaryAdded(_beneficiary);
  }

  /**
   * @notice Allow all addresses to hold power in the governance contract.
   * @dev This is a one-way valve.
   * only callable by the governance contract itself.
   */
  function openFloodgates() external override(IGovernance) onlySelf {
    depositControl.allBeneficiariesAllowed = true;
    emit FloodGatesOpened();
  }

  /**
   * @notice Update the governance proposer.
   * @dev The governance proposer is the address that is allowed to use `propose`.
   *
   * @dev only callable by the governance contract itself.
   *
   * @dev causes all proposals proposed by the previous governance proposer to be `Droppable`.
   *
   * @dev prevents the governance proposer from being set to the governance contract itself.
   *
   * @param _governanceProposer The new governance proposer.
   */
  function updateGovernanceProposer(address _governanceProposer) external override(IGovernance) onlySelf {
    require(_governanceProposer != address(this), Errors.Governance__GovernanceProposerCannotBeSelf());
    governanceProposer = _governanceProposer;
    emit GovernanceProposerUpdated(_governanceProposer);
  }

  /**
   * @notice Update the governance configuration.
   * only callable by the governance contract itself.
   *
   * @dev all existing proposals will use the configuration they were created with.
   */
  function updateConfiguration(Configuration memory _configuration) external override(IGovernance) onlySelf {
    // This following MUST revert if the configuration is invalid
    _configuration.assertValid();

    configuration = CompressedConfigurationLib.compress(_configuration);

    emit ConfigurationUpdated(Timestamp.wrap(block.timestamp));
  }

  /**
   * @notice Deposit funds into the governance contract, transferring ASSET from msg.sender to the governance contract,
   * increasing the power 1:1 of the beneficiary within the governance contract.
   *
   * @dev The beneficiary must be allowed to hold power in the governance contract,
   * according to `depositControl`.
   *
   * Increments the checkpointed power of the specified beneficiary, and the total power of the governance contract.
   *
   * Note that anyone may deposit funds into the governance contract, and the only restriction is that
   * the beneficiary must be allowed to hold power in the governance contract, according to `depositControl`.
   *
   * It is worth pointing out that someone could attempt to spam the deposit function, and increase the cost to vote
   * as a result of creating many checkpoints. In reality though, as the checkpoints are using time as a key it would
   * take ~36 years of continuous spamming to increase the cost to vote by ~66K gas with 12 second block times.
   *
   * @param _beneficiary The beneficiary to increase the power of.
   * @param _amount The amount of funds to deposit, which is converted to power 1:1.
   */
  function deposit(address _beneficiary, uint256 _amount) external override(IGovernance) isDepositAllowed(_beneficiary) {
    ASSET.safeTransferFrom(msg.sender, address(this), _amount);
    users[_beneficiary].add(_amount);
    total.add(_amount);

    emit Deposit(msg.sender, _beneficiary, _amount);
  }

  /**
   * @notice Initiate a withdrawal of funds from the governance contract,
   * decreasing the power of the beneficiary within the governance contract.
   *
   * @dev the withdraw may be finalized by anyone after configuration.getWithdrawalDelay() has passed.
   *
   * @param _to The address that will receive the funds when the withdrawal is finalized.
   * @param _amount The amount of power to reduce, and thus funds to withdraw.
   * @return The id of the withdrawal, passed to `finalizeWithdraw`.
   */
  function initiateWithdraw(address _to, uint256 _amount) external override(IGovernance) returns (uint256) {
    return _initiateWithdraw(msg.sender, _to, _amount, configuration.getWithdrawalDelay());
  }

  /**
   * @notice Finalize a withdrawal of funds from the governance contract,
   * transferring ASSET from the governance contract to the recipient specified in the withdrawal.
   *
   * @dev The withdrawal must not have been claimed, and the delay specified on the withdrawal must have passed.
   *
   * @param _withdrawalId The id of the withdrawal to finalize.
   */
  function finalizeWithdraw(uint256 _withdrawalId) external override(IGovernance) {
    Withdrawal storage withdrawal = withdrawals[_withdrawalId];
    // This is a sanity check, the `recipient` will only be zero for a non-existent withdrawal, so this avoids
    // `finalize`ing non-existent withdrawals. Note, that `_initiateWithdraw` will fail if `_to` is `address(0)`
    require(withdrawal.recipient != address(0), Errors.Governance__WithdrawalNotInitiated());
    require(!withdrawal.claimed, Errors.Governance__WithdrawalAlreadyClaimed());
    require(
      Timestamp.wrap(block.timestamp) >= withdrawal.unlocksAt,
      Errors.Governance__WithdrawalNotUnlockedYet(Timestamp.wrap(block.timestamp), withdrawal.unlocksAt)
    );
    withdrawal.claimed = true;

    emit WithdrawFinalized(_withdrawalId);

    ASSET.safeTransfer(withdrawal.recipient, withdrawal.amount);
  }

  /**
   * @notice Propose a new proposal as the governanceProposer
   *
   * @dev the state of the proposal may be retrieved via `getProposalState`.
   *
   * Note that the `proposer` of the proposal is the *current* governanceProposer; if the governanceProposer
   * no longer matches the one stored in the proposal, the state of the proposal will be `Droppable`.
   *
   * @param _proposal The IPayload address, which is a contract that contains the proposed actions to be executed by the
   * governance.
   * @return The id of the proposal.
   */
  function propose(IPayload _proposal) external override(IGovernance) returns (uint256) {
    require(
      msg.sender == governanceProposer, Errors.Governance__CallerNotGovernanceProposer(msg.sender, governanceProposer)
    );
    return _propose(_proposal, governanceProposer);
  }

  /**
   * @notice Propose a new proposal by withdrawing an existing amount of power from Governance with a longer delay.
   *
   * @dev proposals made in this way are identical to those made by the governanceProposer, with the exception
   * that the "proposer" stored in the proposal is the address of the governance contract itself,
   * which means it will not transition to a "Droppable" state if the governanceProposer changes.
   *
   * @dev this is intended to only be used in an emergency, where the governanceProposer is compromised.
   *
   * @dev We don't actually need to check available power here, since if the msg.sender does not have
   * sufficient balance, the `_initiateWithdraw` would revert with an underflow.
   *
   * @param _proposal The IPayload address, which is a contract that contains the proposed actions to be executed by
   * the governance.
   * @param _to The address that will receive the withdrawn funds when the withdrawal is finalized (see
   * `finalizeWithdraw`)
   * @return The id of the proposal
   */
  function proposeWithLock(IPayload _proposal, address _to) external override(IGovernance) returns (uint256) {
    ProposeWithLockConfiguration memory proposeConfig = configuration.getProposeConfig();
    _initiateWithdraw(msg.sender, _to, proposeConfig.lockAmount, proposeConfig.lockDelay);
    return _propose(_proposal, address(this));
  }

  /**
   * @notice Vote on a proposal.
   * @dev The proposal must be `Active` to vote on it.
   *
   * NOTE: The amount of power to vote is equal to the power of msg.sender at the time
   * just before the proposal became active.
   *
   * The same caller (e.g. the GSE) may `vote` multiple times, voting different ways,
   * so long as their total votes are less than or equal to their available power;
   * each vote is tracked per proposal, per caller within the `ballots` mapping.
   *
   * We keep track of the total yea and nay votes as a `summedBallot` on the proposal in storage.
   *
   * @param _proposalId The id of the proposal to vote on.
   * @param _amount The amount of power to vote with, which must be less than the available power.
   * @param _support The support of the vote.
   */
  function vote(uint256 _proposalId, uint256 _amount, bool _support) external override(IGovernance) {
    ProposalState state = getProposalState(_proposalId);
    require(state == ProposalState.Active, Errors.Governance__ProposalNotActive());

    // Compute the power at the time the proposals goes from pending to active.
    // This is the last second before active, and NOT the first second active, because it would then be possible to
    // alter the power while the proposal is active since all txs in a block have the same timestamp.
    uint256 userPower = users[msg.sender].valueAt(proposals[_proposalId].pendingThrough());

    CompressedBallot userBallot = ballots[_proposalId][msg.sender];

    uint256 availablePower = userPower - (userBallot.getNay() + userBallot.getYea());
    require(_amount <= availablePower, Errors.Governance__InsufficientPower(msg.sender, availablePower, _amount));

    CompressedProposal storage proposal = proposals[_proposalId];
    if (_support) {
      ballots[_proposalId][msg.sender] = userBallot.addYea(_amount);
      proposal.addYea(_amount);
    } else {
      ballots[_proposalId][msg.sender] = userBallot.addNay(_amount);
      proposal.addNay(_amount);
    }

    emit VoteCast(_proposalId, msg.sender, _support, _amount);
  }

  /**
   * @notice Execute a proposal.
   * @dev The proposal must be `Executable` to execute it.
   * If it is, we mark the proposal as `Executed` and execute the actions,
   * simply looping through and calling them.
   *
   * As far as the individual calls, there are 2 safety measures:
   *  - The call cannot target the ASSET which underlies the governance contract
   *  - The call must succeed
   *
   * @param _proposalId The id of the proposal to execute.
   */
  function execute(uint256 _proposalId) external override(IGovernance) {
    ProposalState state = getProposalState(_proposalId);
    require(state == ProposalState.Executable, Errors.Governance__ProposalNotExecutable());

    CompressedProposal storage proposal = proposals[_proposalId];
    proposal.cachedState = ProposalState.Executed;

    IPayload.Action[] memory actions = proposal.payload.getActions();

    for (uint256 i = 0; i < actions.length; i++) {
      require(actions[i].target != address(ASSET), Errors.Governance__CannotCallAsset());
      // We allow calls to EOAs. If you really want be my guest.
      // solhint-disable-next-line avoid-low-level-calls
      (bool success,) = actions[i].target.call(actions[i].data);
      require(success, Errors.Governance__CallFailed(actions[i].target));
    }

    emit ProposalExecuted(_proposalId);
  }

  /**
   * @notice Update a proposal to be `Dropped`.
   * @dev The proposal must be `Droppable` to mark it permanently as `Dropped`.
   * See `getProposalState` for more details.
   *
   * @param _proposalId The id of the proposal to mark as `Dropped`.
   */
  function dropProposal(uint256 _proposalId) external override(IGovernance) {
    CompressedProposal storage self = proposals[_proposalId];
    require(self.cachedState != ProposalState.Dropped, Errors.Governance__ProposalAlreadyDropped());
    require(getProposalState(_proposalId) == ProposalState.Droppable, Errors.Governance__ProposalCannotBeDropped());

    self.cachedState = ProposalState.Dropped;

    emit ProposalDropped(_proposalId);
  }

  /**
   * @notice Get the power of an address at a given timestamp.
   *
   * @param _owner The address to get the power of.
   * @param _ts The timestamp to get the power at.
   * @return The power of the address at the given timestamp.
   */
  function powerAt(address _owner, Timestamp _ts) external view override(IGovernance) returns (uint256) {
    return users[_owner].valueAt(_ts);
  }

  /**
   * @notice Get the power of an address at the current block timestamp.
   *
   * Note that `powerNow` with the current block timestamp is NOT STABLE.
   *
   *  For example, imagine a transaction that performs the following:
   *  1. deposit
   *  2. powerNow
   *  3. deposit
   *  4. powerNow
   *
   *  The powerNow at 4 will be different from the powerNow at 2.
   *
   * @param _owner The address to get the power of.
   * @return The power of the address at the current block timestamp.
   */
  function powerNow(address _owner) external view override(IGovernance) returns (uint256) {
    return users[_owner].valueNow();
  }

  /**
   * @notice Get the total power in Governance at a given timestamp.
   *
   * @param _ts The timestamp to get the power at.
   * @return The total power at the given timestamp.
   */
  function totalPowerAt(Timestamp _ts) external view override(IGovernance) returns (uint256) {
    return total.valueAt(_ts);
  }

  /**
   * @notice Get the total power in Governance at the current block timestamp.
   * Note that `powerNow` with the current block timestamp is NOT STABLE.
   *
   * @return The total power at the current block timestamp.
   */
  function totalPowerNow() external view override(IGovernance) returns (uint256) {
    return total.valueNow();
  }

  /**
   * @notice Check if an address is permitted to hold power in Governance.
   *
   * @param _beneficiary The address to check.
   * @return True if the address is permitted to hold power in Governance.
   */
  function isPermittedInGovernance(address _beneficiary) external view override(IGovernance) returns (bool) {
    return depositControl.isAllowed[_beneficiary];
  }

  /**
   * @notice Check if everyone is permitted to hold power in Governance.
   *
   * @return True if everyone is permitted to hold power in Governance.
   */
  function isAllBeneficiariesAllowed() external view override(IGovernance) returns (bool) {
    return depositControl.allBeneficiariesAllowed;
  }

  function getConfiguration() external view override(IGovernance) returns (Configuration memory) {
    return configuration.decompress();
  }

  /**
   * @notice Get a proposal by its id.
   *
   * @dev   Will return default values (0) for non-existing proposals
   *
   * @param _proposalId The id of the proposal to get.
   * @return The proposal.
   */
  function getProposal(uint256 _proposalId) external view override(IGovernance) returns (Proposal memory) {
    return proposals[_proposalId].decompress();
  }

  /**
   * @notice Get a withdrawal by its id.
   *
   * @dev   Will return default values (0) for non-existing withdrawals
   *
   * @param _withdrawalId The id of the withdrawal to get.
   * @return The withdrawal.
   */
  function getWithdrawal(uint256 _withdrawalId) external view override(IGovernance) returns (Withdrawal memory) {
    return withdrawals[_withdrawalId];
  }

  /**
   * @notice Get a user's ballot for a specific proposal.
   *
   * @dev Returns the uncompressed Ballot struct for external callers.
   *
   * @param _proposalId The id of the proposal.
   * @param _user The address of the user.
   * @return The user's ballot with yea and nay votes.
   */
  function getBallot(uint256 _proposalId, address _user) external view override(IGovernance) returns (Ballot memory) {
    return ballots[_proposalId][_user].decompress();
  }

  /**
   * @notice Get the state of a proposal in the governance system
   *
   * @dev Determine the current state of a proposal based on timestamps, vote results, and governance configuration.
   *
   * @dev NB: the state returned here is LOGICAL, and is the "true state" of the proposal:
   * it need not match the state of the proposal in storage, which is effectively just a cache.
   *
   *  Flow Logic:
   *  1. Check if proposal exists (revert if not)
   *  2. If the cached state of the proposal is "stable" (Executed/Dropped), return that state
   *  3. Check if governance proposer changed (→ Droppable, unless proposed via lock)
   *  4. Time-based state transitions:
   *   - currentTime ≤ pendingThrough() → Pending
   *   - currentTime ≤ activeThrough() → Active
   *   - Vote tabulation check → Rejected if not accepted
   *   - currentTime ≤ queuedThrough() → Queued
   *   - currentTime ≤ executableThrough() → Executable
   *   - Otherwise → Expired
   *
   * @dev State Descriptions:
   *      - Pending: Proposal created but voting hasn't started yet
   *      - Active: Voting is currently open
   *      - Rejected: Voting closed but proposal didn't meet acceptance criteria
   *      - Queued: Proposal accepted and waiting for execution window
   *      - Executable: Proposal can be executed
   *      - Expired: Execution window has passed
   *      - Droppable: Proposer changed
   *      - Dropped: Proposal dropped by calling `dropProposal`
   *      - Executed: Proposal has been successfully executed
   *
   * @dev edge case: it is possible that a proposal be "Droppable" according to the logic here,
   * but no one called `dropProposal`, and then be in a different state later.
   * This can happen if, for whatever reason, the governance proposer stored by this contract changes
   * from the one the proposal is made via, (which would cause this function to return `Droppable`),
   * but then a separate proposal is executed which restores the original governance proposer.
   * So, `Dropped` is permanent, but `Droppable` is not.
   *
   * @param _proposalId The ID of the proposal to check
   * @return The current state of the proposal
   */
  function getProposalState(uint256 _proposalId) public view override(IGovernance) returns (ProposalState) {
    require(_proposalId < proposalCount, Errors.Governance__ProposalDoesNotExists(_proposalId));

    CompressedProposal storage self = proposals[_proposalId];

    // A proposal's state is "stable" after `execute` or `dropProposal` has been called on it.
    // In this case, the state of the proposal as returned by `getProposalState` is the same as the cached state,
    // and the state will not change.
    if (self.cachedState == ProposalState.Executed || self.cachedState == ProposalState.Dropped) {
      return self.cachedState;
    }

    // If the governanceProposer has changed, and the proposal did not come through `proposeWithLock`,
    // the state of the proposal is `Droppable`.
    if (governanceProposer != self.proposer && address(this) != self.proposer) {
      return ProposalState.Droppable;
    }

    Timestamp currentTime = Timestamp.wrap(block.timestamp);

    if (currentTime <= self.pendingThrough()) {
      return ProposalState.Pending;
    }

    if (currentTime <= self.activeThrough()) {
      return ProposalState.Active;
    }

    uint256 totalPower = total.valueAt(self.pendingThrough());
    (VoteTabulationReturn vtr,) = self.voteTabulation(totalPower);
    if (vtr != VoteTabulationReturn.Accepted) {
      return ProposalState.Rejected;
    }

    if (currentTime <= self.queuedThrough()) {
      return ProposalState.Queued;
    }

    if (currentTime <= self.executableThrough()) {
      return ProposalState.Executable;
    }

    return ProposalState.Expired;
  }

  /**
   * @dev reduce the user's power, the total power, and insert a new withdrawal.
   *
   *  The reason for a configurable delay is that `proposeWithLock` creates a withdrawal,
   *  which has a (presumably) very long delay, whereas `initiateWithdraw` has a much shorter delay.
   *
   * @param _from The address to reduce the power of.
   * @param _to The address to send the funds to.
   * @param _amount The amount of power to reduce, and thus funds to withdraw.
   * @param _delay The delay before the funds can be withdrawn.
   * @return The id of the withdrawal.
   */
  function _initiateWithdraw(address _from, address _to, uint256 _amount, Timestamp _delay) internal returns (uint256) {
    require(_to != address(0), Errors.Governance__CannotWithdrawToAddressZero());
    users[_from].sub(_amount);
    total.sub(_amount);

    uint256 withdrawalId = withdrawalCount++;

    withdrawals[withdrawalId] =
      Withdrawal({amount: _amount, unlocksAt: Timestamp.wrap(block.timestamp) + _delay, recipient: _to, claimed: false});

    emit WithdrawInitiated(withdrawalId, _to, _amount);

    return withdrawalId;
  }

  /**
   * @dev create a new proposal. In it we store:
   *
   *  - a copy of the current governance configuration, effectively "freezing" the config for the proposal.
   *      This is done to ensure that in progress proposals that alter the delays etc won't take effect on existing
   *      proposals.
   *  - the summed ballots
   *  - the proposer, which can be:
   *    - the current governanceProposer (which can be updated on the Governance contract), if created via `propose`
   *    - the governance contract itself, if created via `proposeWithLock`
   *
   * @param _proposal The proposal to propose.
   * @param _proposer The address that is proposing the proposal.
   * @return The id of the proposal, which is one less than the current count of proposals.
   */
  function _propose(IPayload _proposal, address _proposer) internal returns (uint256) {
    uint256 proposalId = proposalCount++;

    proposals[proposalId] =
      CompressedProposalLib.create(_proposer, _proposal, Timestamp.wrap(block.timestamp), configuration);

    emit Proposed(proposalId, address(_proposal));

    return proposalId;
  }
}


// File: lib/l1-contracts/src/governance/interfaces/IGovernance.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {IPayload} from "@aztec/governance/interfaces/IPayload.sol";
import {Ballot} from "@aztec/governance/libraries/compressed-data/Ballot.sol";
import {Timestamp} from "@aztec/shared/libraries/TimeMath.sol";

// @notice if this changes, please update the enum in governance.ts
enum ProposalState {
  Pending,
  Active,
  Queued,
  Executable,
  Rejected,
  Executed,
  Droppable,
  Dropped,
  Expired
}

struct ProposeWithLockConfiguration {
  Timestamp lockDelay;
  uint256 lockAmount;
}

struct Configuration {
  ProposeWithLockConfiguration proposeConfig;
  Timestamp votingDelay;
  Timestamp votingDuration;
  Timestamp executionDelay;
  Timestamp gracePeriod;
  uint256 quorum;
  uint256 requiredYeaMargin;
  uint256 minimumVotes;
}

// Configuration for proposals - same as Configuration but without proposeConfig
// since proposeConfig is only used for proposeWithLock, not for the proposal itself
struct ProposalConfiguration {
  Timestamp votingDelay;
  Timestamp votingDuration;
  Timestamp executionDelay;
  Timestamp gracePeriod;
  uint256 quorum;
  uint256 requiredYeaMargin;
  uint256 minimumVotes;
}

struct Proposal {
  ProposalConfiguration config;
  ProposalState cachedState;
  IPayload payload;
  address proposer;
  Timestamp creation;
  Ballot summedBallot;
}

struct Withdrawal {
  uint256 amount;
  Timestamp unlocksAt;
  address recipient;
  bool claimed;
}

interface IGovernance {
  event BeneficiaryAdded(address beneficiary);
  event FloodGatesOpened();

  event Proposed(uint256 indexed proposalId, address indexed proposal);
  event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 amount);
  event ProposalExecuted(uint256 indexed proposalId);
  event ProposalDropped(uint256 indexed proposalId);
  event GovernanceProposerUpdated(address indexed governanceProposer);
  event ConfigurationUpdated(Timestamp indexed time);

  event Deposit(address indexed depositor, address indexed onBehalfOf, uint256 amount);
  event WithdrawInitiated(uint256 indexed withdrawalId, address indexed recipient, uint256 amount);
  event WithdrawFinalized(uint256 indexed withdrawalId);

  function addBeneficiary(address _beneficiary) external;
  function openFloodgates() external;

  function updateGovernanceProposer(address _governanceProposer) external;
  function updateConfiguration(Configuration memory _configuration) external;
  function deposit(address _onBehalfOf, uint256 _amount) external;
  function initiateWithdraw(address _to, uint256 _amount) external returns (uint256);
  function finalizeWithdraw(uint256 _withdrawalId) external;
  function propose(IPayload _proposal) external returns (uint256);
  function proposeWithLock(IPayload _proposal, address _to) external returns (uint256);
  function vote(uint256 _proposalId, uint256 _amount, bool _support) external;
  function execute(uint256 _proposalId) external;
  function dropProposal(uint256 _proposalId) external;

  function isPermittedInGovernance(address _caller) external view returns (bool);
  function isAllBeneficiariesAllowed() external view returns (bool);

  function powerAt(address _owner, Timestamp _ts) external view returns (uint256);
  function powerNow(address _owner) external view returns (uint256);
  function totalPowerAt(Timestamp _ts) external view returns (uint256);
  function totalPowerNow() external view returns (uint256);
  function getProposalState(uint256 _proposalId) external view returns (ProposalState);
  function getConfiguration() external view returns (Configuration memory);
  function getProposal(uint256 _proposalId) external view returns (Proposal memory);
  function getWithdrawal(uint256 _withdrawalId) external view returns (Withdrawal memory);
  function getBallot(uint256 _proposalId, address _user) external view returns (Ballot memory);
}


// File: lib/l1-contracts/src/governance/libraries/ProposalLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {CompressedProposal, CompressedProposalLib} from "@aztec/governance/libraries/compressed-data/Proposal.sol";
import {CompressedTimestamp, CompressedTimeMath} from "@aztec/shared/libraries/CompressedTimeMath.sol";
import {Timestamp} from "@aztec/shared/libraries/TimeMath.sol";
import {Math} from "@oz/utils/math/Math.sol";

enum VoteTabulationReturn {
  Accepted,
  Rejected,
  Invalid
}

enum VoteTabulationInfo {
  TotalPowerLtMinimum,
  VotesNeededEqZero,
  VotesNeededGtTotalPower,
  VotesCastLtVotesNeeded,
  YeaLimitEqZero,
  YeaLimitGtVotesCast,
  YeaLimitEqVotesCast,
  YeaVotesEqVotesCast,
  YeaVotesLeYeaLimit,
  YeaVotesGtYeaLimit
}

/**
 * @notice  Library for governance proposal evaluation and lifecycle management
 *
 *          This library implements the core vote tabulation logic, and has helpers for getting timestamps
 *          for the proposal lifecycle.
 *
 * @dev     VOTING MECHANICS:
 *
 *          The voting system uses three key parameters that interact to determine proposal outcomes:
 *
 *          1. **minimumVotes**: Absolute minimum voting power required in the system
 *             - Prevents proposals when total power is too low for meaningful governance
 *             - Must be > 0 and <= totalPower for valid proposals
 *
 *          2. **quorum**: Percentage of total power that must participate (in 1e18 precision)
 *             - votesNeeded = ceil(totalPower * quorum / 1e18)
 *             - Ensures sufficient community participation before decisions are made
 *             - Example: 30% quorum (0.3e18) with 1000 total power requires ≥300 votes
 *
 *          3. **requiredYeaMargin**: the required minimum difference between the percentage of yea votes,
 *                                    and the percentage of nay votes, in 1e18 precision
 *             - requiredYeaVotesFraction = ceil((1e18 + requiredYeaMargin) / 2)
 *             - requiredYeaVotes = ceil(votesCast * requiredYeaVotesFraction / 1e18)
 *             - Yea votes must be > requiredYeaVotes to pass (strict inequality to avoid ties)
 *             - Example: 20% requiredYeaMargin (0.2e18) means yea needs >60% of cast votes
 *             - Example: 0% requiredYeaMargin means yea needs >50% of cast votes
 *
 *             To see why this is the case, let `y` be the percentage of yea votes,
 *             and `n` be the percentage of nay votes, and `m` be the requiredYeaMargin.
 *
 *             The condition for the proposal to pass is `y - n > m`.
 *             Thus, `y > m + n`, which is equivalent to `y > m + (1 - y)` => `2y > m + 1` => `y > (m + 1) / 2`.
 *
 *          These parameters are included on the proposal itself, which are copied from Governance at the
 *          time the proposal is created.
 *
 * @dev     EXAMPLE SCENARIO:
 *          - Total power: 1000 tokens
 *          - Minimum votes: 100 tokens
 *          - Quorum: 40% (0.4e18)
 *          - Required yea margin: 10% (0.1e18)
 *
 *          For a proposal to pass:
 *          1. Total power (1000) must be ≥ minimum votes (100) ✓
 *          2. Votes needed = ceil(1000 * 0.4) = 400 votes minimum
 *          3. If 500 votes cast (300 yea, 200 nay):
 *             - Quorum met: 500 ≥ 400 ✓
 *             - Required yea votes = ceil(500 * ceil(1.1e18/2) / 1e18) = ceil(500 * 0.55) = 275
 *             - Proposal passes: 300 yea > 275 required yea votes ✓
 *
 * @dev     ROUNDING STRATEGY:
 *          All calculations use ceiling rounding to ensure the protocol is never "underpaid"
 *          in terms of required votes. This prevents edge cases where fractional vote
 *          requirements could round down to zero or insufficient thresholds.
 *
 * @dev     PROPOSAL LIFECYCLE:
 *          The library also manages proposal timing through four phases:
 *          1. Pending: creation → creation + votingDelay
 *          2. Active: pending end → pending end + votingDuration
 *          3. Queued: active end → active end + executionDelay
 *          4. Executable: queued end → queued end + gracePeriod
 */
library ProposalLib {
  using CompressedTimeMath for CompressedTimestamp;
  using CompressedProposalLib for CompressedProposal;
  /**
   * @notice Tabulate the votes for a proposal.
   * @dev This function is used to determine if a proposal has met the acceptance criteria.
   *
   * @param _self The proposal to tabulate the votes for.
   * @param _totalPower The total power (in Governance) at proposal.pendingThrough().
   * @return The vote tabulation result, and additional information.
   */

  function voteTabulation(CompressedProposal storage _self, uint256 _totalPower)
    internal
    view
    returns (VoteTabulationReturn, VoteTabulationInfo)
  {
    if (_totalPower < _self.minimumVotes) {
      return (VoteTabulationReturn.Rejected, VoteTabulationInfo.TotalPowerLtMinimum);
    }

    uint256 votesNeeded = Math.mulDiv(_totalPower, _self.quorum, 1e18, Math.Rounding.Ceil);
    if (votesNeeded == 0) {
      return (VoteTabulationReturn.Invalid, VoteTabulationInfo.VotesNeededEqZero);
    }
    if (votesNeeded > _totalPower) {
      return (VoteTabulationReturn.Invalid, VoteTabulationInfo.VotesNeededGtTotalPower);
    }

    (uint256 yea, uint256 nay) = _self.getVotes();
    uint256 votesCast = nay + yea;
    if (votesCast < votesNeeded) {
      return (VoteTabulationReturn.Rejected, VoteTabulationInfo.VotesCastLtVotesNeeded);
    }

    // Edge case where all the votes are yea, no need to compute requiredApprovalVotes.
    // ConfigurationLib enforces that requiredYeaMargin is <= 1e18,
    // i.e. we cannot require more votes to be yes than total votes.
    if (yea == votesCast) {
      return (VoteTabulationReturn.Accepted, VoteTabulationInfo.YeaVotesEqVotesCast);
    }

    uint256 requiredApprovalVotesFraction = Math.ceilDiv(1e18 + _self.requiredYeaMargin, 2);
    uint256 requiredApprovalVotes = Math.mulDiv(votesCast, requiredApprovalVotesFraction, 1e18, Math.Rounding.Ceil);

    /*if (requiredApprovalVotes == 0) {
      // It should be impossible to hit this case as `requiredApprovalVotesFraction` cannot be 0,
      // and due to rounding up, only way to hit this would be if `votesCast = 0`,
      // which is already handled as `votesCast >= votesNeeded` and `votesNeeded > 0`.
      return (VoteTabulationReturn.Invalid, VoteTabulationInfo.YeaLimitEqZero);
    }*/
    if (requiredApprovalVotes > votesCast) {
      return (VoteTabulationReturn.Invalid, VoteTabulationInfo.YeaLimitGtVotesCast);
    }

    // We want to see that there are MORE votes on yea than needed
    // We explicitly need MORE to ensure we don't "tie".
    // If we need as many yea as there are votes, we know it is impossible already.
    // due to the check earlier, that summedBallot.yea == votesCast.
    if (yea <= requiredApprovalVotes) {
      return (VoteTabulationReturn.Rejected, VoteTabulationInfo.YeaVotesLeYeaLimit);
    }

    return (VoteTabulationReturn.Accepted, VoteTabulationInfo.YeaVotesGtYeaLimit);
  }

  /**
   * @notice Get when the pending phase ends
   * @param _compressed Storage pointer to compressed proposal
   * @return The timestamp when pending phase ends
   */
  function pendingThrough(CompressedProposal storage _compressed) internal view returns (Timestamp) {
    return _compressed.creation.decompress() + _compressed.votingDelay.decompress();
  }

  /**
   * @notice Get when the active phase ends
   * @param _compressed Storage pointer to compressed proposal
   * @return The timestamp when active phase ends
   */
  function activeThrough(CompressedProposal storage _compressed) internal view returns (Timestamp) {
    return pendingThrough(_compressed) + _compressed.votingDuration.decompress();
  }

  /**
   * @notice Get when the queued phase ends
   * @param _compressed Storage pointer to compressed proposal
   * @return The timestamp when queued phase ends
   */
  function queuedThrough(CompressedProposal storage _compressed) internal view returns (Timestamp) {
    return activeThrough(_compressed) + _compressed.executionDelay.decompress();
  }

  /**
   * @notice Get when the executable phase ends
   * @param _compressed Storage pointer to compressed proposal
   * @return The timestamp when executable phase ends
   */
  function executableThrough(CompressedProposal storage _compressed) internal view returns (Timestamp) {
    return queuedThrough(_compressed) + _compressed.gracePeriod.decompress();
  }
}


// File: lib/l1-contracts/src/governance/proposer/GovernanceProposer.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {IGSE} from "@aztec/governance/GSE.sol";
import {GSEPayload} from "@aztec/governance/GSEPayload.sol";
import {IEmpire} from "@aztec/governance/interfaces/IEmpire.sol";
import {IGovernance} from "@aztec/governance/interfaces/IGovernance.sol";
import {IGovernanceProposer} from "@aztec/governance/interfaces/IGovernanceProposer.sol";
import {IPayload} from "@aztec/governance/interfaces/IPayload.sol";
import {IRegistry} from "@aztec/governance/interfaces/IRegistry.sol";
import {EmpireBase} from "./EmpireBase.sol";

/**
 * @title GovernanceProposer
 * An implementation of EmpireBase, used to propose payloads to governance from sequencers on the canonical rollup.
 *
 * Note: any payload which passes through this contract will have a call to GSEPayload.amIValid appended to the
 * list of actions before it is proposed to Governance.
 * This will cause the proposal to revert if >2/3 of all stake in the GSE are not staked on the latest rollup after
 * the *original* payload is executed by Governance. Unless the latest and canonical rollup diverge, as that indicates
 * a misconfiguration issue (see GSEPayload for more details).
 */
contract GovernanceProposer is IGovernanceProposer, EmpireBase {
  IRegistry public immutable REGISTRY;
  IGSE public immutable GSE;

  /**
   * @dev Mapping of proposal ID to the proposer address.
   * This allows instances to see if they were the proposer of a proposal
   * after the payload is `propose`ed to Governance.
   * Instances that *did* propose a proposal are willing to vote on it in Governance.
   * See `StakingLib.vote` for more details.
   */
  mapping(uint256 proposalId => address proposer) internal proposalProposer;

  /**
   * @notice Constructor for the GovernanceProposer contract.
   *
   * @dev The _executionDelayInRounds are set to 0, as there already is a delay in the governance contract.
   *      If this was not the case, the delay could be applied here.
   *
   * @param _registry The registry contract address.
   * @param _gse The GSE contract address.
   * @param _quorumSize The number of signals needed in a round for a payload to pass.
   * @param _roundSize The number of signals that can be cast in a round.
   */
  constructor(IRegistry _registry, IGSE _gse, uint256 _quorumSize, uint256 _roundSize)
    EmpireBase(_quorumSize, _roundSize, 5, 0)
  {
    REGISTRY = _registry;
    GSE = _gse;
  }

  function getProposalProposer(uint256 _proposalId) external view override(IGovernanceProposer) returns (address) {
    return proposalProposer[_proposalId];
  }

  /**
   * @dev Returns the address of the Governance contract, i.e. the contract at which
   * we will `propose` a winning proposal.
   */
  function getGovernance() public view override(IGovernanceProposer) returns (address) {
    return REGISTRY.getGovernance();
  }

  /**
   * @dev A hook used by the EmpireBase to determine who is the current block builder (block "proposer"),
   * and thus may signal.
   *
   * This contract only respects the canonical rollup.
   */
  function getInstance() public view override(EmpireBase, IEmpire) returns (address) {
    return address(REGISTRY.getCanonicalRollup());
  }

  /**
   * @dev Called by the EmpireBase contract in `submitRoundWinner`, which asserts that the payload
   * has enough support to be proposed to Governance.
   *
   * Note that it wraps the original payload in a GSEPayload before pushing into the Governance contract.
   *
   * This creates additional checks, namely that *after* the original payload is executed,
   * the canonical rollup (both the instance and the "magical address") has at least 2/3 of the total stake.
   *
   * @param _payload The payload to propose to the governance contract.
   * @return true if the proposal was proposed successfully, reverts otherwise.
   */
  function _handleRoundWinner(IPayload _payload) internal override(EmpireBase) returns (bool) {
    GSEPayload extendedPayload = new GSEPayload(_payload, GSE, REGISTRY);
    uint256 proposalId = IGovernance(getGovernance()).propose(IPayload(address(extendedPayload)));
    proposalProposer[proposalId] = getInstance();
    return true;
  }
}


// File: lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.3.0) (token/ERC20/utils/SafeERC20.sol)

pragma solidity ^0.8.20;

import {IERC20} from "../IERC20.sol";
import {IERC1363} from "../../../interfaces/IERC1363.sol";

/**
 * @title SafeERC20
 * @dev Wrappers around ERC-20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    /**
     * @dev An operation with an ERC-20 token failed.
     */
    error SafeERC20FailedOperation(address token);

    /**
     * @dev Indicates a failed `decreaseAllowance` request.
     */
    error SafeERC20FailedDecreaseAllowance(address spender, uint256 currentAllowance, uint256 requestedDecrease);

    /**
     * @dev Transfer `value` amount of `token` from the calling contract to `to`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transfer, (to, value)));
    }

    /**
     * @dev Transfer `value` amount of `token` from `from` to `to`, spending the approval given by `from` to the
     * calling contract. If `token` returns no value, non-reverting calls are assumed to be successful.
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transferFrom, (from, to, value)));
    }

    /**
     * @dev Variant of {safeTransfer} that returns a bool instead of reverting if the operation is not successful.
     */
    function trySafeTransfer(IERC20 token, address to, uint256 value) internal returns (bool) {
        return _callOptionalReturnBool(token, abi.encodeCall(token.transfer, (to, value)));
    }

    /**
     * @dev Variant of {safeTransferFrom} that returns a bool instead of reverting if the operation is not successful.
     */
    function trySafeTransferFrom(IERC20 token, address from, address to, uint256 value) internal returns (bool) {
        return _callOptionalReturnBool(token, abi.encodeCall(token.transferFrom, (from, to, value)));
    }

    /**
     * @dev Increase the calling contract's allowance toward `spender` by `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     *
     * IMPORTANT: If the token implements ERC-7674 (ERC-20 with temporary allowance), and if the "client"
     * smart contract uses ERC-7674 to set temporary allowances, then the "client" smart contract should avoid using
     * this function. Performing a {safeIncreaseAllowance} or {safeDecreaseAllowance} operation on a token contract
     * that has a non-zero temporary allowance (for that particular owner-spender) will result in unexpected behavior.
     */
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 oldAllowance = token.allowance(address(this), spender);
        forceApprove(token, spender, oldAllowance + value);
    }

    /**
     * @dev Decrease the calling contract's allowance toward `spender` by `requestedDecrease`. If `token` returns no
     * value, non-reverting calls are assumed to be successful.
     *
     * IMPORTANT: If the token implements ERC-7674 (ERC-20 with temporary allowance), and if the "client"
     * smart contract uses ERC-7674 to set temporary allowances, then the "client" smart contract should avoid using
     * this function. Performing a {safeIncreaseAllowance} or {safeDecreaseAllowance} operation on a token contract
     * that has a non-zero temporary allowance (for that particular owner-spender) will result in unexpected behavior.
     */
    function safeDecreaseAllowance(IERC20 token, address spender, uint256 requestedDecrease) internal {
        unchecked {
            uint256 currentAllowance = token.allowance(address(this), spender);
            if (currentAllowance < requestedDecrease) {
                revert SafeERC20FailedDecreaseAllowance(spender, currentAllowance, requestedDecrease);
            }
            forceApprove(token, spender, currentAllowance - requestedDecrease);
        }
    }

    /**
     * @dev Set the calling contract's allowance toward `spender` to `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful. Meant to be used with tokens that require the approval
     * to be set to zero before setting it to a non-zero value, such as USDT.
     *
     * NOTE: If the token implements ERC-7674, this function will not modify any temporary allowance. This function
     * only sets the "standard" allowance. Any temporary allowance will remain active, in addition to the value being
     * set here.
     */
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        bytes memory approvalCall = abi.encodeCall(token.approve, (spender, value));

        if (!_callOptionalReturnBool(token, approvalCall)) {
            _callOptionalReturn(token, abi.encodeCall(token.approve, (spender, 0)));
            _callOptionalReturn(token, approvalCall);
        }
    }

    /**
     * @dev Performs an {ERC1363} transferAndCall, with a fallback to the simple {ERC20} transfer if the target has no
     * code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * Reverts if the returned value is other than `true`.
     */
    function transferAndCallRelaxed(IERC1363 token, address to, uint256 value, bytes memory data) internal {
        if (to.code.length == 0) {
            safeTransfer(token, to, value);
        } else if (!token.transferAndCall(to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} transferFromAndCall, with a fallback to the simple {ERC20} transferFrom if the target
     * has no code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * Reverts if the returned value is other than `true`.
     */
    function transferFromAndCallRelaxed(
        IERC1363 token,
        address from,
        address to,
        uint256 value,
        bytes memory data
    ) internal {
        if (to.code.length == 0) {
            safeTransferFrom(token, from, to, value);
        } else if (!token.transferFromAndCall(from, to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} approveAndCall, with a fallback to the simple {ERC20} approve if the target has no
     * code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * NOTE: When the recipient address (`to`) has no code (i.e. is an EOA), this function behaves as {forceApprove}.
     * Opposedly, when the recipient address (`to`) has code, this function only attempts to call {ERC1363-approveAndCall}
     * once without retrying, and relies on the returned value to be true.
     *
     * Reverts if the returned value is other than `true`.
     */
    function approveAndCallRelaxed(IERC1363 token, address to, uint256 value, bytes memory data) internal {
        if (to.code.length == 0) {
            forceApprove(token, to, value);
        } else if (!token.approveAndCall(to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     *
     * This is a variant of {_callOptionalReturnBool} that reverts if call fails to meet the requirements.
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        uint256 returnSize;
        uint256 returnValue;
        assembly ("memory-safe") {
            let success := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            // bubble errors
            if iszero(success) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            returnSize := returndatasize()
            returnValue := mload(0)
        }

        if (returnSize == 0 ? address(token).code.length == 0 : returnValue != 1) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     *
     * This is a variant of {_callOptionalReturn} that silently catches all reverts and returns a bool instead.
     */
    function _callOptionalReturnBool(IERC20 token, bytes memory data) private returns (bool) {
        bool success;
        uint256 returnSize;
        uint256 returnValue;
        assembly ("memory-safe") {
            success := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            returnSize := returndatasize()
            returnValue := mload(0)
        }
        return success && (returnSize == 0 ? address(token).code.length > 0 : returnValue == 1);
    }
}


// File: lib/l1-contracts/src/governance/Bn254LibWrapper.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {BN254Lib, G1Point, G2Point} from "@aztec/shared/libraries/BN254Lib.sol";
import {IBn254LibWrapper} from "./interfaces/IBn254LibWrapper.sol";

contract Bn254LibWrapper is IBn254LibWrapper {
  function proofOfPossession(
    G1Point memory _publicKeyInG1,
    G2Point memory _publicKeyInG2,
    G1Point memory _proofOfPossession
  ) external view override(IBn254LibWrapper) returns (bool) {
    return BN254Lib.proofOfPossession(_publicKeyInG1, _publicKeyInG2, _proofOfPossession);
  }

  function g1ToDigestPoint(G1Point memory pk1) external view override(IBn254LibWrapper) returns (G1Point memory) {
    return BN254Lib.g1ToDigestPoint(pk1);
  }
}


// File: lib/l1-contracts/src/governance/interfaces/IPayload.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

interface IPayload {
  struct Action {
    address target;
    bytes data;
  }

  /**
   * @notice  A URI that can be used to refer to where a non-coder human readable description
   *          of the payload can be found.
   *
   * @dev     Not used in the contracts, so could be any string really
   *
   * @return - Ideally a useful URI for the payload description
   */
  function getURI() external view returns (string memory);

  function getActions() external view returns (Action[] memory);
}


// File: lib/l1-contracts/src/governance/libraries/AddressSnapshotLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Aztec Labs.
pragma solidity >=0.8.27;

import {SafeCast} from "@oz/utils/math/SafeCast.sol";
import {Checkpoints} from "@oz/utils/structs/Checkpoints.sol";

/**
 * @notice Structure to store a set of addresses with their historical snapshots
 * @param size The timestamped history of the number of addresses in the set
 * @param indexToAddressHistory Mapping of index to array of timestamped address history
 * @param addressToCurrentIndex Mapping of address to its current index in the set
 */
struct SnapshottedAddressSet {
  // This size must also be snapshotted
  Checkpoints.Trace224 size;
  // For each index, store the timestamped history of addresses
  mapping(uint256 index => Checkpoints.Trace224) indexToAddressHistory;
  // For each address, store its current index in the set
  mapping(address addr => Index index) addressToCurrentIndex;
}

struct Index {
  bool exists;
  uint224 index;
}

// AddressSnapshotLib
error AddressSnapshotLib__IndexOutOfBounds(uint256 index, uint256 size); // 0xd789b71a
error AddressSnapshotLib__CannotAddAddressZero();

/**
 * @title AddressSnapshotLib
 * @notice A library for managing a set of addresses with historical snapshots
 * @dev This library provides functionality similar to EnumerableSet but can track addresses across time
 *      and allows querying the state of addresses at any point in time. This is used to track the
 *      list of stakers on a particular rollup instance in the GSE throughout time.
 *
 * The SnapshottedAddressSet is maintained such that the you can take a timestamp, and from it:
 * 1. Get the `size` of the set at that timestamp
 * 2. Query the first `size` indices in `indexToAddressHistory` at that timestamp to get a set of addresses of size
 * `size`
 */
library AddressSnapshotLib {
  using SafeCast for *;
  using Checkpoints for Checkpoints.Trace224;

  /**
   * @notice Adds a validator to the set
   * @param _self The storage reference to the set
   * @param _address The address to add
   * @return bool True if the address was added, false if it was already present
   */
  function add(SnapshottedAddressSet storage _self, address _address) internal returns (bool) {
    require(_address != address(0), AddressSnapshotLib__CannotAddAddressZero());
    // Prevent against double insertion
    if (_self.addressToCurrentIndex[_address].exists) {
      return false;
    }

    uint224 index = _self.size.latest();
    _self.addressToCurrentIndex[_address] = Index({exists: true, index: index});

    uint32 key = block.timestamp.toUint32();

    _self.indexToAddressHistory[index].push(key, uint160(_address).toUint224());
    _self.size.push(key, (index + 1).toUint224());

    return true;
  }

  /**
   * @notice Removes a address from the set by address
   *
   * @param _self The storage reference to the set
   * @param _address The address of the address to remove
   * @return bool True if the address was removed, false if it wasn't found
   */
  function remove(SnapshottedAddressSet storage _self, address _address) internal returns (bool) {
    Index memory index = _self.addressToCurrentIndex[_address];
    if (!index.exists) {
      return false;
    }

    return _remove(_self, index.index, _address);
  }

  /**
   * @notice Removes a validator from the set by index
   * @param _self The storage reference to the set
   * @param _index The index of the validator to remove
   * @return bool True if the validator was removed, reverts otherwise
   */
  function remove(SnapshottedAddressSet storage _self, uint224 _index) internal returns (bool) {
    address _address = address(_self.indexToAddressHistory[_index].latest().toUint160());
    return _remove(_self, _index, _address);
  }

  /**
   * @notice Removes a validator from the set
   * @param _self The storage reference to the set
   * @param _index The index of the validator to remove
   * @param _address The address to remove
   * @return bool True if the validator was removed, reverts otherwise
   */
  function _remove(SnapshottedAddressSet storage _self, uint224 _index, address _address) internal returns (bool) {
    uint224 currentSize = _self.size.latest();
    if (_index >= currentSize) {
      revert AddressSnapshotLib__IndexOutOfBounds(_index, currentSize);
    }

    // Mark the address to remove as not existing
    _self.addressToCurrentIndex[_address] = Index({exists: false, index: 0});

    // Now we need to update the indexToAddressHistory.
    // Suppose the current size is 3, and we are removing Bob from index 1, and Charlie is at index 2.
    // We effectively push Charlie into the snapshot at index 1,
    // then update Charlie in addressToCurrentIndex to reflect the new index of 1.

    uint224 lastIndex = currentSize - 1;
    uint32 key = block.timestamp.toUint32();

    // If not removing the last item, swap the value of the last item into the `_index` to remove
    if (lastIndex != _index) {
      address lastValidator = address(_self.indexToAddressHistory[lastIndex].latest().toUint160());

      _self.addressToCurrentIndex[lastValidator] = Index({exists: true, index: _index.toUint224()});
      _self.indexToAddressHistory[_index].push(key, uint160(lastValidator).toUint224());
    }

    // Then "pop" the last index by setting the value to `address(0)`
    _self.indexToAddressHistory[lastIndex].push(key, uint224(0));

    // Finally, we update the size to reflect the new size of the set.
    _self.size.push(key, (lastIndex).toUint224());
    return true;
  }

  /**
   * @notice Gets the current address at a specific index at the time right now
   * @param _self The storage reference to the set
   * @param _index The index to query
   * @return address The current address at the given index
   */
  function at(SnapshottedAddressSet storage _self, uint256 _index) internal view returns (address) {
    return getAddressFromIndexAtTimestamp(_self, _index, block.timestamp.toUint32());
  }

  /**
   * @notice Gets the address at a specific index and timestamp
   * @param _self The storage reference to the set
   * @param _index The index to query
   * @param _timestamp The timestamp to query
   * @return address The address at the given index and timestamp
   */
  function getAddressFromIndexAtTimestamp(SnapshottedAddressSet storage _self, uint256 _index, uint32 _timestamp)
    internal
    view
    returns (address)
  {
    uint256 size = lengthAtTimestamp(_self, _timestamp);
    require(_index < size, AddressSnapshotLib__IndexOutOfBounds(_index, size));

    // Since the _index is less than the size, we know that the address at _index
    // exists at/before _timestamp.
    uint224 addr = _self.indexToAddressHistory[_index].upperLookup(_timestamp);
    return address(addr.toUint160());
  }

  /**
   * @notice Gets the address at a specific index and timestamp
   *
   * @dev     The caller MUST have ensure that `_index` < `size`
   *          at the `_timestamp` provided.
   * @dev     Primed for recent checkpoints in the address history.
   *
   * @param _self The storage reference to the set
   * @param _index The index to query
   * @param _timestamp The timestamp to query
   * @return address The address at the given index and timestamp
   */
  function unsafeGetRecentAddressFromIndexAtTimestamp(
    SnapshottedAddressSet storage _self,
    uint256 _index,
    uint32 _timestamp
  ) internal view returns (address) {
    uint224 addr = _self.indexToAddressHistory[_index].upperLookupRecent(_timestamp);
    return address(addr.toUint160());
  }

  /**
   * @notice Gets the current size of the set
   * @param _self The storage reference to the set
   * @return uint256 The number of addresses in the set
   */
  function length(SnapshottedAddressSet storage _self) internal view returns (uint256) {
    return lengthAtTimestamp(_self, block.timestamp.toUint32());
  }

  /**
   * @notice Gets the size of the set at a specific timestamp
   * @param _self The storage reference to the set
   * @param _timestamp The timestamp to query
   * @return uint256 The number of addresses in the set at the given timestamp
   *
   * @dev Note, the values returned from this function are in flux if the timestamp is in the future.
   */
  function lengthAtTimestamp(SnapshottedAddressSet storage _self, uint32 _timestamp) internal view returns (uint256) {
    return _self.size.upperLookup(_timestamp);
  }

  /**
   * @notice Gets all current addresses in the set
   *
   * @dev This function is only used in tests.
   *
   * @param _self The storage reference to the set
   * @return address[] Array of all current addresses in the set
   */
  function values(SnapshottedAddressSet storage _self) internal view returns (address[] memory) {
    return valuesAtTimestamp(_self, block.timestamp.toUint32());
  }

  /**
   * @notice Gets all addresses in the set at a specific timestamp
   *
   * @dev This function is only used in tests.
   *
   * @param _self The storage reference to the set
   * @param _timestamp The timestamp to query
   * @return address[] Array of all addresses in the set at the given timestamp
   *
   * @dev Note, the values returned from this function are in flux if the timestamp is in the future.
   *
   */
  function valuesAtTimestamp(SnapshottedAddressSet storage _self, uint32 _timestamp)
    internal
    view
    returns (address[] memory)
  {
    uint256 size = lengthAtTimestamp(_self, _timestamp);
    address[] memory vals = new address[](size);
    for (uint256 i; i < size;) {
      vals[i] = getAddressFromIndexAtTimestamp(_self, i, _timestamp);

      unchecked {
        ++i;
      }
    }
    return vals;
  }

  function contains(SnapshottedAddressSet storage _self, address _address) internal view returns (bool) {
    return _self.addressToCurrentIndex[_address].exists;
  }
}


// File: lib/l1-contracts/src/governance/libraries/DepositDelegationLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {Checkpoints, CheckpointedUintLib} from "@aztec/governance/libraries/CheckpointedUintLib.sol";
import {Errors} from "@aztec/governance/libraries/Errors.sol";
import {Timestamp} from "@aztec/shared/libraries/TimeMath.sol";

// A struct storing balance and delegatee for an attester
struct DepositPosition {
  uint256 balance;
  address delegatee;
}

// A struct storing all the positions for an instance along with a supply
struct DepositLedger {
  mapping(address attester => DepositPosition position) positions;
  Checkpoints.Trace224 supply;
}

// A struct storing the voting power used for each proposal for a delegatee
// as well as their checkpointed voting power
struct VotingAccount {
  mapping(uint256 proposalId => uint256 powerUsed) powerUsed;
  Checkpoints.Trace224 votingPower;
}

// A struct storing the ledgers for the individual rollup instances, the voting
// account for delegatees and the total supply.
struct DepositAndDelegationAccounting {
  mapping(address instance => DepositLedger ledger) ledgers;
  mapping(address delegatee => VotingAccount votingAccount) votingAccounts;
  Checkpoints.Trace224 supply;
}

// This library have a lot of overlap with `Votes.sol` from Openzeppelin,
// It mainly differs as it is a library to allow us having many accountings in the same contract
// the unit of time and allowing multiple uses of power.
library DepositDelegationLib {
  using CheckpointedUintLib for Checkpoints.Trace224;

  event DelegateChanged(address indexed attester, address oldDelegatee, address newDelegatee);
  event DelegateVotesChanged(address indexed delegatee, uint256 oldValue, uint256 newValue);

  /**
   * @notice Increase the balance of an `_attester` on `_instance` by `_amount`,
   *         increases the voting power of the delegatee equally.
   *
   * @param _self The DepositAndDelegationAccounting struct to modify in storage
   * @param _instance The instance that the attester is on
   * @param _attester The attester to increase the balance of
   * @param _amount The amount to increase by
   */
  function increaseBalance(
    DepositAndDelegationAccounting storage _self,
    address _instance,
    address _attester,
    uint256 _amount
  ) internal {
    if (_amount == 0) {
      return;
    }

    DepositLedger storage instance = _self.ledgers[_instance];

    instance.positions[_attester].balance += _amount;
    moveVotingPower(_self, address(0), instance.positions[_attester].delegatee, _amount);

    instance.supply.add(_amount);
    _self.supply.add(_amount);
  }

  /**
   * @notice Decrease the balance of an `_attester` on `_instance` by `_amount`,
   *         decrease the voting power of the delegatee equally
   *
   * @param _self The DepositAndDelegationAccounting struct to modify in storage
   * @param _instance The instance that the attester is on
   * @param _attester The attester to decrease the balance of
   * @param _amount The amount to decrease by
   */
  function decreaseBalance(
    DepositAndDelegationAccounting storage _self,
    address _instance,
    address _attester,
    uint256 _amount
  ) internal {
    if (_amount == 0) {
      return;
    }

    DepositLedger storage instance = _self.ledgers[_instance];

    instance.positions[_attester].balance -= _amount;
    moveVotingPower(_self, instance.positions[_attester].delegatee, address(0), _amount);

    instance.supply.sub(_amount);
    _self.supply.sub(_amount);
  }

  /**
   * @notice    Use `_amount` of `_delegatee`'s voting power on `_proposalId`
   *            The `_delegatee`'s voting power based on the snapshot at `_timestamp`
   *
   * @dev       If different timestamps are passed, it can cause mismatch in the amount of
   *            power that can be voted with, so it is very important that it is stable for
   *            a given `_proposalId`
   *
   * @param _self       - The DelegationDate struct to modify in storage
   * @param _delegatee  - The delegatee using their power
   * @param _proposalId - The id to use for accounting
   * @param _timestamp  - The timestamp for voting power of the specific `_proposalId`
   * @param _amount     - The amount of power to use
   */
  function usePower(
    DepositAndDelegationAccounting storage _self,
    address _delegatee,
    uint256 _proposalId,
    Timestamp _timestamp,
    uint256 _amount
  ) internal {
    uint256 powerAt = getVotingPowerAt(_self, _delegatee, _timestamp);
    uint256 powerUsed = getPowerUsed(_self, _delegatee, _proposalId);

    require(
      powerAt >= powerUsed + _amount, Errors.Delegation__InsufficientPower(_delegatee, powerAt, powerUsed + _amount)
    );

    _self.votingAccounts[_delegatee].powerUsed[_proposalId] += _amount;
  }

  /**
   * @notice Delegate the voting power of an `_attester` on a specific `_instance` to a `_delegatee`
   *
   * @param _self The DepositAndDelegationAccounting struct to modify in storage
   * @param _instance The instance the attester is on
   * @param _attester The attester to delegate the voting power of
   * @param _delegatee The delegatee to delegate the voting power to
   */
  function delegate(
    DepositAndDelegationAccounting storage _self,
    address _instance,
    address _attester,
    address _delegatee
  ) internal {
    address oldDelegate = getDelegatee(_self, _instance, _attester);
    if (oldDelegate == _delegatee) {
      return;
    }
    _self.ledgers[_instance].positions[_attester].delegatee = _delegatee;
    emit DelegateChanged(_attester, oldDelegate, _delegatee);

    moveVotingPower(_self, oldDelegate, _delegatee, getBalanceOf(_self, _instance, _attester));
  }

  /**
   * @notice Convenience function to remove delegation from `_attester` at `_instance`
   *
   * @dev Similar as calling `delegate` with `_delegatee = address(0)`
   *
   * @param _self The DepositAndDelegationAccounting struct to modify in storage
   * @param _instance The instance that the attester is on
   * @param _attester The attester to undelegate the voting power of
   */
  function undelegate(DepositAndDelegationAccounting storage _self, address _instance, address _attester) internal {
    delegate(_self, _instance, _attester, address(0));
  }

  /**
   * @notice Get the balance of an `_attester` on `_instance`
   *
   * @param _self The DepositAndDelegationAccounting struct to read from
   * @param _instance The instance that the attester is on
   * @param _attester The attester to get the balance of
   *
   * @return The balance of the attester
   */
  function getBalanceOf(DepositAndDelegationAccounting storage _self, address _instance, address _attester)
    internal
    view
    returns (uint256)
  {
    return _self.ledgers[_instance].positions[_attester].balance;
  }

  /**
   * @notice Get the supply of an `_instance`
   *
   * @param _self The DepositAndDelegationAccounting struct to read from
   * @param _instance The instance to get the supply of
   *
   * @return The supply of the instance
   */
  function getSupplyOf(DepositAndDelegationAccounting storage _self, address _instance) internal view returns (uint256) {
    return _self.ledgers[_instance].supply.valueNow();
  }

  /**
   * @notice Get the total supply of all instances
   *
   * @param _self The DepositAndDelegationAccounting struct to read from
   *
   * @return The total supply of all instances
   */
  function getSupply(DepositAndDelegationAccounting storage _self) internal view returns (uint256) {
    return _self.supply.valueNow();
  }

  /**
   * @notice Get the delegatee of an `_attester` on `_instance`
   *
   * @param _self The DepositAndDelegationAccounting struct to read from
   * @param _instance The instance that the attester is on
   * @param _attester The attester to get the delegatee of
   *
   * @return The delegatee of the attester
   */
  function getDelegatee(DepositAndDelegationAccounting storage _self, address _instance, address _attester)
    internal
    view
    returns (address)
  {
    return _self.ledgers[_instance].positions[_attester].delegatee;
  }

  /**
   * @notice Get the voting power of a `_delegatee`
   *
   * @param _self The DepositAndDelegationAccounting struct to read from
   * @param _delegatee The delegatee to get the voting power of
   *
   * @return The voting power of the delegatee
   */
  function getVotingPower(DepositAndDelegationAccounting storage _self, address _delegatee)
    internal
    view
    returns (uint256)
  {
    return _self.votingAccounts[_delegatee].votingPower.valueNow();
  }

  /**
   * @notice Get the voting power of a `_delegatee` at a specific `_timestamp`
   *
   * @param _self The DepositAndDelegationAccounting struct to read from
   * @param _delegatee The delegatee to get the voting power of
   * @param _timestamp The timestamp to get the voting power at
   *
   * @return The voting power of the delegatee at the specific `_timestamp`
   */
  function getVotingPowerAt(DepositAndDelegationAccounting storage _self, address _delegatee, Timestamp _timestamp)
    internal
    view
    returns (uint256)
  {
    return _self.votingAccounts[_delegatee].votingPower.valueAt(_timestamp);
  }

  /**
   * @notice Get the power used by a `_delegatee` on a specific `_proposalId`
   *
   * @param _self The DepositAndDelegationAccounting struct to read from
   * @param _delegatee The delegatee to get the power used by
   * @param _proposalId The proposal to get the power used on
   *
   * @return The voting power used by the `_delegatee` at `_proposalId`
   */
  function getPowerUsed(DepositAndDelegationAccounting storage _self, address _delegatee, uint256 _proposalId)
    internal
    view
    returns (uint256)
  {
    return _self.votingAccounts[_delegatee].powerUsed[_proposalId];
  }

  /**
   * @notice Move `_amount` of voting power from the delegatee of `_from` to the delegatee of `_to`
   *
   * @dev If the `_from` is `address(0)` the decrease is skipped, and it is effectively a mint
   * @dev If the `_to` is `address(0)` the increase is skipped, and it is effectively a burn
   *
   * @param _self The DepositAndDelegationAccounting struct to modify in storage
   * @param _from The address to move the voting power from
   * @param _to The address to move the voting power to
   * @param _amount The amount of voting power to move
   */
  function moveVotingPower(DepositAndDelegationAccounting storage _self, address _from, address _to, uint256 _amount)
    private
  {
    if (_from == _to || _amount == 0) {
      return;
    }

    if (_from != address(0)) {
      (uint256 oldValue, uint256 newValue) = _self.votingAccounts[_from].votingPower.sub(_amount);
      emit DelegateVotesChanged(_from, oldValue, newValue);
    }

    if (_to != address(0)) {
      (uint256 oldValue, uint256 newValue) = _self.votingAccounts[_to].votingPower.add(_amount);
      emit DelegateVotesChanged(_to, oldValue, newValue);
    }
  }
}


// File: lib/l1-contracts/src/governance/libraries/Errors.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {IPayload} from "@aztec/governance/interfaces/IPayload.sol";
import {Slot, Timestamp} from "@aztec/shared/libraries/TimeMath.sol";

/**
 * @title Errors Library
 * @author Aztec Labs
 * @notice Library that contains errors used throughout the Aztec governance
 * Errors are prefixed with the contract name to make it easy to identify where the error originated
 * when there are multiple contracts that could have thrown the error.
 */
library Errors {
  error Governance__CallerNotGovernanceProposer(address caller, address governanceProposer);
  error Governance__GovernanceProposerCannotBeSelf();
  error Governance__CallerNotSelf(address caller, address self);
  error Governance__CallerCannotBeSelf();
  error Governance__InsufficientPower(address voter, uint256 have, uint256 required);
  error Governance__CannotWithdrawToAddressZero();
  error Governance__WithdrawalNotInitiated();
  error Governance__WithdrawalAlreadyClaimed();
  error Governance__WithdrawalNotUnlockedYet(Timestamp currentTime, Timestamp unlocksAt);
  error Governance__ProposalNotActive();
  error Governance__ProposalNotExecutable();
  error Governance__CannotCallAsset();
  error Governance__CallFailed(address target);
  error Governance__ProposalDoesNotExists(uint256 proposalId);
  error Governance__ProposalAlreadyDropped();
  error Governance__ProposalCannotBeDropped();
  error Governance__DepositNotAllowed();

  error Governance__CheckpointedUintLib__InsufficientValue(address owner, uint256 have, uint256 required);
  error Governance__CheckpointedUintLib__NotInPast();

  error Governance__ConfigurationLib__InvalidMinimumVotes();
  error Governance__ConfigurationLib__LockAmountTooSmall();
  error Governance__ConfigurationLib__LockAmountTooBig();
  error Governance__ConfigurationLib__QuorumTooSmall();
  error Governance__ConfigurationLib__QuorumTooBig();
  error Governance__ConfigurationLib__RequiredYeaMarginTooBig();
  error Governance__ConfigurationLib__TimeTooSmall(string name);
  error Governance__ConfigurationLib__TimeTooBig(string name);

  error EmpireBase__FailedToSubmitRoundWinner(IPayload payload);
  error EmpireBase__InstanceHaveNoCode(address instance);
  error EmpireBase__InsufficientSignals(uint256 signalsCast, uint256 signalsNeeded);
  error EmpireBase__InvalidQuorumAndRoundSize(uint256 quorumSize, uint256 roundSize);
  error EmpireBase__QuorumCannotBeLargerThanRoundSize(uint256 quorumSize, uint256 roundSize);
  error EmpireBase__InvalidLifetimeAndExecutionDelay(uint256 lifetimeInRounds, uint256 executionDelayInRounds);
  error EmpireBase__OnlyProposerCanSignal(address caller, address proposer);
  error EmpireBase__PayloadAlreadySubmitted(uint256 roundNumber);
  error EmpireBase__PayloadCannotBeAddressZero();
  error EmpireBase__RoundTooOld(uint256 roundNumber, uint256 currentRoundNumber);
  error EmpireBase__RoundTooNew(uint256 roundNumber, uint256 currentRoundNumber);
  error EmpireBase__SignalAlreadyCastForSlot(Slot slot);
  error GovernanceProposer__GSEPayloadInvalid();

  error CoinIssuer__InsufficientMintAvailable(uint256 available, uint256 needed); // 0xa1cc8799
  error CoinIssuer__InvalidConfiguration();

  error Registry__RollupAlreadyRegistered(address rollup); // 0x3c34eabf
  error Registry__RollupNotRegistered(uint256 version);
  error Registry__NoRollupsRegistered();

  error RewardDistributor__InvalidCaller(address caller, address canonical); // 0xb95e39f6

  error GSE__NotRollup(address);
  error GSE__GovernanceAlreadySet();
  error GSE__InvalidRollupAddress(address);
  error GSE__RollupAlreadyRegistered(address);
  error GSE__NotLatestRollup(address);
  error GSE__AlreadyRegistered(address, address);
  error GSE__NothingToExit(address);
  error GSE__InsufficientBalance(uint256, uint256);
  error GSE__FailedToRemove(address);
  error GSE__InstanceDoesNotExist(address);
  error GSE__NotWithdrawer(address, address);
  error GSE__OutOfBounds(uint256, uint256);
  error GSE__FatalError(string);
  error GSE__InvalidProofOfPossession();
  error GSE__CannotChangePublicKeys(uint256 existingPk1x, uint256 existingPk1y);
  error GSE__ProofOfPossessionAlreadySeen(bytes32 hashedPK1);

  error Delegation__InsufficientPower(address, uint256, uint256);
}


// File: lib/openzeppelin-contracts/contracts/access/Ownable.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (access/Ownable.sol)

pragma solidity ^0.8.20;

import {Context} from "../utils/Context.sol";

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * The initial owner is set to the address provided by the deployer. This can
 * later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    /**
     * @dev The caller account is not authorized to perform an operation.
     */
    error OwnableUnauthorizedAccount(address account);

    /**
     * @dev The owner is not a valid owner account. (eg. `address(0)`)
     */
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the address provided by the deployer as the initial owner.
     */
    constructor(address initialOwner) {
        if (initialOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(initialOwner);
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        if (owner() != _msgSender()) {
            revert OwnableUnauthorizedAccount(_msgSender());
        }
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby disabling any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}


// File: lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (utils/cryptography/ECDSA.sol)

pragma solidity ^0.8.20;

/**
 * @dev Elliptic Curve Digital Signature Algorithm (ECDSA) operations.
 *
 * These functions can be used to verify that a message was signed by the holder
 * of the private keys of a given address.
 */
library ECDSA {
    enum RecoverError {
        NoError,
        InvalidSignature,
        InvalidSignatureLength,
        InvalidSignatureS
    }

    /**
     * @dev The signature derives the `address(0)`.
     */
    error ECDSAInvalidSignature();

    /**
     * @dev The signature has an invalid length.
     */
    error ECDSAInvalidSignatureLength(uint256 length);

    /**
     * @dev The signature has an S value that is in the upper half order.
     */
    error ECDSAInvalidSignatureS(bytes32 s);

    /**
     * @dev Returns the address that signed a hashed message (`hash`) with `signature` or an error. This will not
     * return address(0) without also returning an error description. Errors are documented using an enum (error type)
     * and a bytes32 providing additional information about the error.
     *
     * If no error is returned, then the address can be used for verification purposes.
     *
     * The `ecrecover` EVM precompile allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {MessageHashUtils-toEthSignedMessageHash} on it.
     *
     * Documentation for signature generation:
     * - with https://web3js.readthedocs.io/en/v1.3.4/web3-eth-accounts.html#sign[Web3.js]
     * - with https://docs.ethers.io/v5/api/signer/#Signer-signMessage[ethers]
     */
    function tryRecover(
        bytes32 hash,
        bytes memory signature
    ) internal pure returns (address recovered, RecoverError err, bytes32 errArg) {
        if (signature.length == 65) {
            bytes32 r;
            bytes32 s;
            uint8 v;
            // ecrecover takes the signature parameters, and the only way to get them
            // currently is to use assembly.
            assembly ("memory-safe") {
                r := mload(add(signature, 0x20))
                s := mload(add(signature, 0x40))
                v := byte(0, mload(add(signature, 0x60)))
            }
            return tryRecover(hash, v, r, s);
        } else {
            return (address(0), RecoverError.InvalidSignatureLength, bytes32(signature.length));
        }
    }

    /**
     * @dev Returns the address that signed a hashed message (`hash`) with
     * `signature`. This address can then be used for verification purposes.
     *
     * The `ecrecover` EVM precompile allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {MessageHashUtils-toEthSignedMessageHash} on it.
     */
    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        (address recovered, RecoverError error, bytes32 errorArg) = tryRecover(hash, signature);
        _throwError(error, errorArg);
        return recovered;
    }

    /**
     * @dev Overload of {ECDSA-tryRecover} that receives the `r` and `vs` short-signature fields separately.
     *
     * See https://eips.ethereum.org/EIPS/eip-2098[ERC-2098 short signatures]
     */
    function tryRecover(
        bytes32 hash,
        bytes32 r,
        bytes32 vs
    ) internal pure returns (address recovered, RecoverError err, bytes32 errArg) {
        unchecked {
            bytes32 s = vs & bytes32(0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
            // We do not check for an overflow here since the shift operation results in 0 or 1.
            uint8 v = uint8((uint256(vs) >> 255) + 27);
            return tryRecover(hash, v, r, s);
        }
    }

    /**
     * @dev Overload of {ECDSA-recover} that receives the `r and `vs` short-signature fields separately.
     */
    function recover(bytes32 hash, bytes32 r, bytes32 vs) internal pure returns (address) {
        (address recovered, RecoverError error, bytes32 errorArg) = tryRecover(hash, r, vs);
        _throwError(error, errorArg);
        return recovered;
    }

    /**
     * @dev Overload of {ECDSA-tryRecover} that receives the `v`,
     * `r` and `s` signature fields separately.
     */
    function tryRecover(
        bytes32 hash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal pure returns (address recovered, RecoverError err, bytes32 errArg) {
        // EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
        // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
        // the valid range for s in (301): 0 < s < secp256k1n ÷ 2 + 1, and for v in (302): v ∈ {27, 28}. Most
        // signatures from current libraries generate a unique signature with an s-value in the lower half order.
        //
        // If your library generates malleable signatures, such as s-values in the upper range, calculate a new s-value
        // with 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - s1 and flip v from 27 to 28 or
        // vice versa. If your library also generates signatures with 0/1 for v instead 27/28, add 27 to v to accept
        // these malleable signatures as well.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return (address(0), RecoverError.InvalidSignatureS, s);
        }

        // If the signature is valid (and not malleable), return the signer address
        address signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) {
            return (address(0), RecoverError.InvalidSignature, bytes32(0));
        }

        return (signer, RecoverError.NoError, bytes32(0));
    }

    /**
     * @dev Overload of {ECDSA-recover} that receives the `v`,
     * `r` and `s` signature fields separately.
     */
    function recover(bytes32 hash, uint8 v, bytes32 r, bytes32 s) internal pure returns (address) {
        (address recovered, RecoverError error, bytes32 errorArg) = tryRecover(hash, v, r, s);
        _throwError(error, errorArg);
        return recovered;
    }

    /**
     * @dev Optionally reverts with the corresponding custom error according to the `error` argument provided.
     */
    function _throwError(RecoverError error, bytes32 errorArg) private pure {
        if (error == RecoverError.NoError) {
            return; // no error: do nothing
        } else if (error == RecoverError.InvalidSignature) {
            revert ECDSAInvalidSignature();
        } else if (error == RecoverError.InvalidSignatureLength) {
            revert ECDSAInvalidSignatureLength(uint256(errorArg));
        } else if (error == RecoverError.InvalidSignatureS) {
            revert ECDSAInvalidSignatureS(errorArg);
        }
    }
}


// File: lib/l1-contracts/src/core/libraries/rollup/ValidatorSelectionLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {RollupStore} from "@aztec/core/interfaces/IRollup.sol";
import {ValidatorSelectionStorage} from "@aztec/core/interfaces/IValidatorSelection.sol";
import {SampleLib} from "@aztec/core/libraries/crypto/SampleLib.sol";
import {Errors} from "@aztec/core/libraries/Errors.sol";
import {AttestationLib, CommitteeAttestations} from "@aztec/core/libraries/rollup/AttestationLib.sol";
import {StakingLib} from "@aztec/core/libraries/rollup/StakingLib.sol";
import {STFLib} from "@aztec/core/libraries/rollup/STFLib.sol";
import {Timestamp, Slot, Epoch, TimeLib} from "@aztec/core/libraries/TimeLib.sol";
import {SignatureLib, Signature} from "@aztec/shared/libraries/SignatureLib.sol";
import {ECDSA} from "@oz/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@oz/utils/cryptography/MessageHashUtils.sol";
import {SafeCast} from "@oz/utils/math/SafeCast.sol";
import {SlotDerivation} from "@oz/utils/SlotDerivation.sol";
import {Checkpoints} from "@oz/utils/structs/Checkpoints.sol";
import {EnumerableSet} from "@oz/utils/structs/EnumerableSet.sol";
import {TransientSlot} from "@oz/utils/TransientSlot.sol";

/**
 * @title ValidatorSelectionLib
 * @author Aztec Labs
 * @notice Core library responsible for validator selection, committee management, and proposer verification in the
 * Aztec rollup.
 *
 * @dev This library implements the validator selection system:
 *      - Epoch-based committee sampling
 *      - Slot-based proposer selection within committee members
 *      - Signature verification for block proposals and attestations
 *      - Committee commitment validation and caching mechanisms
 *      - Randomness seed management for unpredictable but deterministic selection
 *
 *      Key Components:
 *
 *      1. Committee Selection:
 *         - At the start of each epoch, a committee is sampled from the active validator set
 *         - Committee size is configurable at deployment (targetCommitteeSize), and must be met
 *         - Selection uses cryptographic randomness (prevrandao + epoch)
 *         - Committee remains stable throughout the entire epoch for consistency
 *         - Committee commitment is stored on-chain and validated against reconstructed committees
 *
 *      2. Proposer Selection:
 *         - For each slot within an epoch, one committee member is selected as the proposer (this may change)
 *         - Selection is deterministic based on epoch, slot, and the epoch's sample seed
 *         - Proposers have exclusive rights to propose blocks during their assigned slot
 *         - Proposer verification ensures only the correct validator can submit blocks
 *
 *      3. Attestation System:
 *         - Committee members attest to blocks by providing signatures
 *         - Attestations serve dual purpose: data availability and state validation
 *         - Blocks require >2/3 committee signatures to be considered valid
 *         - Signatures are verified against expected committee members using ECDSA recovery
 *         - Mixed signature/address format allows optimization (addresses included only for non-signing members,
 *           addresses for signing members can be recovered from the signatures and hence are not needed for DA
 *           purposes)
 *         - Signature verification is delayed until proof submission to save gas
 *
 *      4. Seed Management:
 *         - Sample seeds determine committee and proposer selection for each epoch
 *         - Seeds use prevrandao from L1 blocks combined with epoch number for unpredictability
 *         - Prevrandao are set 2 epochs in advance to prevent last-minute manipulation and provide L1-reorg resistance
 *         - First two epochs use randao values (type(uint224).max) for bootstrap (this results in the committee
 *           being predictable in the first 2 epochs which is considered acceptable when bootstrapping the network)
 *
 *      5. Caching and Optimization:
 *         - Transient storage caches proposer computations within the same transaction
 *           - This is used when signaling for a governance or slashing payload after a block proposal
 *         - Committee commitments are stored to avoid recomputation during verification
 *         - Validator indices are sampled once and reused for address resolution
 *
 *      Integration with Rollup System:
 *      - Called from RollupCore.setupEpoch() to initialize epoch committees
 *      - Used in ProposeLib.propose() for proposer verification during block submission
 *      - Integrates with StakingLib to resolve validator addresses from staking indices
 *      - Works with InvalidateLib for committee verification during invalidation
 *
 *      Security Model:
 *      - Randomness comes from L1 prevrandao
 *      - Committee selection happens before epoch start, preventing manipulation
 *      - Signature verification ensures only legitimate committee members can attest
 *      - Committee commitments prevent committee substitution attacks
 *      - Two-epoch delay in seed setting prevents last-minute influence and provides L1-reorg resistance
 *
 *      Time-based Architecture:
 *      - Epochs define committee boundaries (committee stable within epoch)
 *      - Slots define proposer assignments (one proposer per slot)
 *      - Sampling uses a lagging time for the epoch to ensure validator set stability
 *      - Validator set snapshots taken at deterministic timestamps for consistency
 */
library ValidatorSelectionLib {
  using EnumerableSet for EnumerableSet.AddressSet;
  using MessageHashUtils for bytes32;
  using SignatureLib for Signature;
  using TimeLib for Timestamp;
  using TimeLib for Epoch;
  using TimeLib for Slot;
  using Checkpoints for Checkpoints.Trace224;
  using SafeCast for *;
  using TransientSlot for *;
  using SlotDerivation for string;
  using SlotDerivation for bytes32;
  using AttestationLib for CommitteeAttestations;

  /**
   * @dev Stack struct used in verifyAttestations to avoid stack too deep errors
   *      Used when reconstructing the committee commitment from the attestations
   * @param proposerIndex Index of the proposer within the committee
   * @param index Working index for iteration (unused in current implementation)
   * @param needed Number of signatures required (2/3 + 1 of committee size)
   * @param signaturesRecovered Number of valid signatures found
   * @param reconstructedCommittee Array of committee member addresses reconstructed from attestations
   */
  struct VerifyStack {
    uint256 proposerIndex;
    uint256 index;
    uint256 needed;
    uint256 signaturesRecovered;
    address[] reconstructedCommittee;
  }

  bytes32 private constant VALIDATOR_SELECTION_STORAGE_POSITION = keccak256("aztec.validator_selection.storage");
  // Namespace for cached proposer computations
  string private constant PROPOSER_NAMESPACE = "aztec.validator_selection.transient.proposer";

  /**
   * @notice Initializes the validator selection system with target committee size
   * @dev Sets up the initial configuration and bootstrap seeds for the first two epochs.
   *      The first two epochs use maximum seed values for startup.
   * @param _targetCommitteeSize The desired number of validators in each epoch's committee
   */
  function initialize(uint256 _targetCommitteeSize, uint256 _lagInEpochs) internal {
    ValidatorSelectionStorage storage store = getStorage();
    store.targetCommitteeSize = _targetCommitteeSize.toUint32();
    store.lagInEpochs = _lagInEpochs.toUint32();

    checkpointRandao(Epoch.wrap(0));
  }

  /**
   * @notice Performs epoch setup by sampling the committee and setting future seeds
   * @dev This function handles the epoch transition by:
   *      1. Retrieving the sample seed for the current epoch
   *      2. Setting the sample seed for the next epoch (if not already set)
   *      3. Sampling and storing the committee for the current epoch (if not already done)
   *
   *      This setup ensures that each epoch has a stable committee and that future epochs
   *      have their randomness seeds prepared in advance.
   * @param _epochNumber The epoch number to set up
   */
  function setupEpoch(Epoch _epochNumber) internal {
    ValidatorSelectionStorage storage store = getStorage();

    bytes32 committeeCommitment = store.committeeCommitments[_epochNumber];
    if (committeeCommitment != bytes32(0)) {
      // We already have the commitment stored for the epoch meaning the epoch has already been setup.
      return;
    }

    //################ Seeds ################
    // Get the sample seed for this current epoch.
    uint256 sampleSeed = getSampleSeed(_epochNumber);

    // Checkpoint randao for future sampling if required
    // function handles the case where it is already set
    checkpointRandao(_epochNumber);

    //################ Committee ################
    // If the committee is not set for this epoch, we need to sample it
    address[] memory committee = sampleValidators(_epochNumber, sampleSeed);
    store.committeeCommitments[_epochNumber] = computeCommitteeCommitment(committee);
  }

  /**
   * @notice Verifies that the block proposal has been signed by the correct proposer
   * @dev Validates proposer eligibility and signature for block proposals by:
   *      1. Attempting to load cached proposer from transient storage
   *      2. If not cached, reconstructing committee from attestations and verifying against stored commitment
   *      3. Computing proposer index using epoch, slot, and sample seed
   *      4. Verifying the proposer has provided a valid signature in the attestations
   *
   *      The attestation is checked by reconstructing the committee commitment from the attestations and signers,
   *      and then ensuring it matches the stored commitment for the epoch.
   *
   *      Uses transient storage caching to avoid recomputation within the same transaction. (This caching mechanism is
   *      commonly used when a proposer signals in governance and submits a proposal within the same transaction - then
   *      `getProposerAt` function is called).
   * @param _slot The slot of the block being proposed
   * @param _epochNumber The epoch number of the block
   * @param _attestations The committee attestations for the block proposal
   * @param _signers The addresses of the committee members that signed the attestations. Provided in order to not have
   * to recover them from their attestations' signatures (and hence save gas). The addresses of the non-signing
   * committee members are directly included in the attestations.
   * @param _digest The digest of the block being proposed
   * @param _updateCache Flag to identify that the proposer should be written to transient cache.
   * @custom:reverts Errors.ValidatorSelection__InvalidCommitteeCommitment if reconstructed committee doesn't match
   * stored commitment
   * @custom:reverts Errors.ValidatorSelection__MissingProposerSignature if proposer hasn't signed their attestation
   * @custom:reverts SignatureLib verification errors if proposer signature is invalid
   */
  function verifyProposer(
    Slot _slot,
    Epoch _epochNumber,
    CommitteeAttestations memory _attestations,
    address[] memory _signers,
    bytes32 _digest,
    Signature memory _attestationsAndSignersSignature,
    bool _updateCache
  ) internal {
    uint256 proposerIndex;
    address proposer;

    {
      // Load the committee commitment for the epoch
      (bytes32 committeeCommitment, uint256 committeeSize) = getCommitteeCommitmentAt(_epochNumber);

      // If the rollup is *deployed* with a target committee size of 0, we skip the validation.
      // Note: This generally only happens in test setups; In production, the target committee is non-zero,
      // and one can see in `sampleValidators` that we will revert if the target committee size is not met.
      if (committeeSize == 0) {
        return;
      }

      // Reconstruct the committee from the attestations and signers
      address[] memory committee = _attestations.reconstructCommitteeFromSigners(_signers, committeeSize);

      // Check reconstructed committee commitment matches the expected one for the epoch
      bytes32 reconstructedCommitment = computeCommitteeCommitment(committee);
      if (reconstructedCommitment != committeeCommitment) {
        revert Errors.ValidatorSelection__InvalidCommitteeCommitment(reconstructedCommitment, committeeCommitment);
      }

      // Get the proposer from the committee based on the epoch, slot, and sample seed
      uint256 sampleSeed = getSampleSeed(_epochNumber);
      proposerIndex = computeProposerIndex(_epochNumber, _slot, sampleSeed, committeeSize);
      proposer = committee[proposerIndex];
    }

    // We check that the proposer agrees with the proposal by checking that he attested to it. If we fail to get
    // the proposer's attestation signature or if we fail to verify it, we revert.
    bool hasProposerSignature = _attestations.isSignature(proposerIndex);
    if (!hasProposerSignature) {
      revert Errors.ValidatorSelection__MissingProposerSignature(proposer, proposerIndex);
    }

    // Check if the signature is correct
    bytes32 digest = _digest.toEthSignedMessageHash();
    Signature memory signature = _attestations.getSignature(proposerIndex);
    SignatureLib.verify(signature, proposer, digest);

    // Check that the proposer have signed the `_attestations|_signers` data such that invalid `_attestations|_signers`
    // data can be attributed to the `proposer` specifically.
    bytes32 attestationsAndSignersDigest =
      _attestations.getAttestationsAndSignersDigest(_signers).toEthSignedMessageHash();
    SignatureLib.verify(_attestationsAndSignersSignature, proposer, attestationsAndSignersDigest);

    if (_updateCache) {
      setCachedProposer(_slot, proposer, proposerIndex);
    }
  }

  /**
   * @notice Verifies committee attestations meet the required threshold and signature validity
   * @dev Performs attestation validation by:
   *      1. Retrieving stored committee commitment and target committee size
   *      2. Computing proposer index for signature verification optimization
   *      3. Extracting and verifying signatures from packed attestation data
   *      4. Reconstructing committee addresses from signatures and provided addresses
   *      5. Validating reconstructed committee matches stored commitment
   *      6. Ensuring at least 2/3 + 1 committee members provided signatures
   *
   *      Each committee attestation is either their:
   *      - Signature (65 bytes: v, r, s) for attestation
   *      - Address (20 bytes) for non-signing members
   *
   *      Note that providing the addresses of non-signing members allows for reconstructing the committee commitment
   *      directly from calldata.
   *
   *      Skips validation entirely if target committee size is 0 (test configurations).
   * @param _slot The slot of the block
   * @param _epochNumber The epoch of the block
   * @param _attestations The packed signatures and addresses of committee members
   * @param _digest The digest of the block that attestations are signed over
   * @custom:reverts Errors.ValidatorSelection__InsufficientAttestations if less than 2/3 + 1 signatures provided
   * @custom:reverts Errors.ValidatorSelection__InvalidCommitteeCommitment if reconstructed committee doesn't match
   * stored commitment
   */
  function verifyAttestations(
    Slot _slot,
    Epoch _epochNumber,
    CommitteeAttestations memory _attestations,
    bytes32 _digest
  ) internal {
    (bytes32 committeeCommitment, uint256 targetCommitteeSize) = getCommitteeCommitmentAt(_epochNumber);

    // If the rollup is *deployed* with a target committee size of 0, we skip the validation.
    // Note: This generally only happens in test setups; In production, the target committee is non-zero,
    // and one can see in `sampleValidators` that we will revert if the target committee size is not met.
    if (targetCommitteeSize == 0) {
      return;
    }

    VerifyStack memory stack = VerifyStack({
      proposerIndex: computeProposerIndex(_epochNumber, _slot, getSampleSeed(_epochNumber), targetCommitteeSize),
      needed: (targetCommitteeSize << 1) / 3 + 1, // targetCommitteeSize * 2 / 3 + 1, but cheaper
      index: 0,
      signaturesRecovered: 0,
      reconstructedCommittee: new address[](targetCommitteeSize)
    });

    bytes32 digest = _digest.toEthSignedMessageHash();

    bytes memory signaturesOrAddresses = _attestations.signaturesOrAddresses;
    uint256 dataPtr;
    assembly {
      dataPtr := add(signaturesOrAddresses, 0x20) // Skip length, cache pointer
    }

    unchecked {
      for (uint256 i = 0; i < targetCommitteeSize; ++i) {
        bool isSignature = _attestations.isSignature(i);

        if (isSignature) {
          uint8 v;
          bytes32 r;
          bytes32 s;

          assembly {
            v := byte(0, mload(dataPtr))
            dataPtr := add(dataPtr, 1)
            r := mload(dataPtr)
            dataPtr := add(dataPtr, 32)
            s := mload(dataPtr)
            dataPtr := add(dataPtr, 32)
          }

          ++stack.signaturesRecovered;
          stack.reconstructedCommittee[i] = ECDSA.recover(digest, v, r, s);
        } else {
          address addr;
          assembly {
            addr := shr(96, mload(dataPtr))
            dataPtr := add(dataPtr, 20)
          }
          stack.reconstructedCommittee[i] = addr;
        }
      }
    }

    require(
      stack.signaturesRecovered >= stack.needed,
      Errors.ValidatorSelection__InsufficientAttestations(stack.needed, stack.signaturesRecovered)
    );

    // Check the committee commitment
    bytes32 reconstructedCommitment = computeCommitteeCommitment(stack.reconstructedCommittee);
    if (reconstructedCommitment != committeeCommitment) {
      revert Errors.ValidatorSelection__InvalidCommitteeCommitment(reconstructedCommitment, committeeCommitment);
    }
  }

  /**
   * @notice Caches proposer information in transient storage for the current transaction
   * @dev Uses EIP-1153 transient storage to cache proposer data, avoiding recomputation within the same transaction.
   *      Packs proposer address (160 bits) and index (96 bits) into a single 32-byte slot for efficiency.
   * @param _slot The slot to cache the proposer for
   * @param _proposer The proposer's address
   * @param _proposerIndex The proposer's index within the committee
   * @custom:reverts Errors.ValidatorSelection__ProposerIndexTooLarge if proposer index exceeds uint96 max
   */
  function setCachedProposer(Slot _slot, address _proposer, uint256 _proposerIndex) internal {
    require(_proposerIndex <= type(uint96).max, Errors.ValidatorSelection__ProposerIndexTooLarge(_proposerIndex));
    bytes32 packed = bytes32(uint256(uint160(_proposer))) | (bytes32(_proposerIndex) << 160);
    PROPOSER_NAMESPACE.erc7201Slot().deriveMapping(Slot.unwrap(_slot)).asBytes32().tstore(packed);
  }

  /**
   * @notice Gets the proposer for a specific slot, using cache or computing if necessary
   * @dev First checks transient storage cache, then computes proposer if not cached.
   *      Computation involves sampling validator indices and selecting based on slot.
   * @param _slot The slot to get the proposer for
   * @return proposer The address of the proposer for the slot
   * @return proposerIndex The index of the proposer within the committee, zero address and index if committee size is
   * 0 (ie test configuration).
   */
  function getProposerAt(Slot _slot) internal returns (address, uint256) {
    (address cachedProposer, uint256 cachedProposerIndex) = getCachedProposer(_slot);
    if (cachedProposer != address(0)) {
      return (cachedProposer, cachedProposerIndex);
    }

    Epoch epochNumber = _slot.epochFromSlot();

    uint256 sampleSeed = getSampleSeed(epochNumber);
    (uint32 ts, uint256[] memory indices) = sampleValidatorsIndices(epochNumber, sampleSeed);
    uint256 committeeSize = indices.length;
    if (committeeSize == 0) {
      return (address(0), 0);
    }
    uint256 proposerIndex = computeProposerIndex(epochNumber, _slot, sampleSeed, committeeSize);
    return (StakingLib.getAttesterFromIndexAtTime(indices[proposerIndex], Timestamp.wrap(ts)), proposerIndex);
  }

  /**
   * @notice Samples validator addresses for a specific epoch using cryptographic randomness
   * @dev Samples validator indices first, then resolves to addresses at the appropriate timestamp.
   *      Only used internally for epoch setup - should never be called for past or distant future epochs.
   * @param _epoch The epoch to sample validators for
   * @param _seed The cryptographic seed for sampling randomness
   * @return The array of validator addresses selected for the committee
   */
  function sampleValidators(Epoch _epoch, uint256 _seed) internal returns (address[] memory) {
    (uint32 ts, uint256[] memory indices) = sampleValidatorsIndices(_epoch, _seed);
    return StakingLib.getAttestersFromIndicesAtTime(Timestamp.wrap(ts), indices);
  }

  /**
   * @notice Gets the committee addresses for a specific epoch
   * @dev Retrieves the sample seed for the epoch and uses it to sample the validator committee.
   *      This function will trigger committee sampling if not already done for the epoch.
   * @param _epochNumber The epoch to get the committee for
   * @return The array of committee member addresses for the epoch
   */
  function getCommitteeAt(Epoch _epochNumber) internal returns (address[] memory) {
    uint256 seed = getSampleSeed(_epochNumber);
    return sampleValidators(_epochNumber, seed);
  }

  /**
   * @notice Gets the committee commitment and size for an epoch
   * @dev Retrieves the stored committee commitment, or computes it if not yet stored.
   *      The commitment is a keccak256 hash of the committee member addresses array.
   * @param _epochNumber The epoch to get the committee commitment for
   * @return committeeCommitment The keccak256 hash of the committee member addresses
   * @return committeeSize The target committee size (same for all epochs)
   */
  function getCommitteeCommitmentAt(Epoch _epochNumber)
    internal
    returns (bytes32 committeeCommitment, uint256 committeeSize)
  {
    ValidatorSelectionStorage storage store = getStorage();

    committeeCommitment = store.committeeCommitments[_epochNumber];
    if (committeeCommitment == 0) {
      // This is an edge case that can happen if `setupEpoch` has not been called (see documentation of
      // `RollupCore.setupEpoch` for details), so we compute the commitment again to guarantee that we get a real value.
      committeeCommitment = computeCommitteeCommitment(sampleValidators(_epochNumber, getSampleSeed(_epochNumber)));
    }

    return (committeeCommitment, store.targetCommitteeSize);
  }

  /**
   * @notice Checkpoints randao value for future usage
   * @dev Checks if already stored before storing the randao value.
   * @param _epoch The current epoch
   */
  function checkpointRandao(Epoch _epoch) internal {
    ValidatorSelectionStorage storage store = getStorage();

    // Check if the latest checkpoint is for the next epoch
    // It should be impossible that zero epoch snapshots exist, as in the genesis state we push the first values
    // into the store
    (, uint32 mostRecentTs,) = store.randaos.latestCheckpoint();
    uint32 ts = Timestamp.unwrap(_epoch.toTimestamp()).toUint32();

    // If the most recently stored epoch is less than the epoch we are querying, then we need to store randao for
    // later use. We truncate to save storage costs.
    if (mostRecentTs < ts) {
      store.randaos.push(ts, uint224(block.prevrandao));
    }
  }

  /**
   * @notice Validates if a specific validator can propose a block at a given time and chain state
   * @dev Performs comprehensive validation including:
   *      - Slot timing (must be after the last block's slot)
   *      - Archive consistency (must build on current chain tip)
   *      - Proposer authorization (must be the designated proposer for the slot)
   * @param _ts The timestamp of the proposed block
   * @param _archive The archive root the block claims to build on
   * @param _who The address attempting to propose the block
   * @return slot The slot number derived from the timestamp
   * @return blockNumber The next block number that will be assigned
   * @custom:reverts Errors.Rollup__SlotAlreadyInChain if trying to propose for a past slot
   * @custom:reverts Errors.Rollup__InvalidArchive if archive doesn't match current chain tip
   * @custom:reverts Errors.ValidatorSelection__InvalidProposer if _who is not the designated proposer
   */
  function canProposeAtTime(Timestamp _ts, bytes32 _archive, address _who) internal returns (Slot, uint256) {
    Slot slot = _ts.slotFromTimestamp();
    RollupStore storage rollupStore = STFLib.getStorage();

    // Pending chain tip
    uint256 pendingBlockNumber = STFLib.getEffectivePendingBlockNumber(_ts);

    Slot lastSlot = STFLib.getSlotNumber(pendingBlockNumber);

    require(slot > lastSlot, Errors.Rollup__SlotAlreadyInChain(lastSlot, slot));

    // Make sure that the proposer is up to date and on the right chain (ie no reorgs)
    bytes32 tipArchive = rollupStore.archives[pendingBlockNumber];
    require(tipArchive == _archive, Errors.Rollup__InvalidArchive(tipArchive, _archive));

    (address proposer,) = getProposerAt(slot);
    require(proposer == _who, Errors.ValidatorSelection__InvalidProposer(proposer, _who));

    return (slot, pendingBlockNumber + 1);
  }

  /**
   * @notice Retrieves cached proposer information from transient storage
   * @dev Reads packed proposer data (address + index) from EIP-1153 transient storage.
   *      Returns zero values if no proposer is cached for the slot.
   * @param _slot The slot to check for cached proposer
   * @return proposer The cached proposer address (address(0) if not cached)
   * @return proposerIndex The cached proposer index (0 if not cached)
   */
  function getCachedProposer(Slot _slot) internal view returns (address proposer, uint256 proposerIndex) {
    bytes32 packed = PROPOSER_NAMESPACE.erc7201Slot().deriveMapping(Slot.unwrap(_slot)).asBytes32().tload();
    // Extract address from lower 160 bits
    proposer = address(uint160(uint256(packed)));
    // Extract uint96 from upper 96 bits
    proposerIndex = uint256(packed >> 160);
  }

  /**
   * @notice Converts an epoch number to the timestamp used for validator set sampling
   * @dev Calculates the sampling timestamp by:
   *      1. Taking the epoch start timestamp
   *      2. Subtracting `lagInEpochs` full epoch duration to ensure stability
   *
   *      This ensures validator set sampling uses stable historical data that won't be
   *      affected by last-minute changes or L1 reorgs during synchronization.
   * @param _epoch The epoch to calculate sampling time for
   * @return The Unix timestamp (uint32) to use for validator set sampling
   */
  function epochToSampleTime(Epoch _epoch) internal view returns (uint32) {
    uint32 sub = getStorage().lagInEpochs * TimeLib.getEpochDurationInSeconds().toUint32();
    return Timestamp.unwrap(_epoch.toTimestamp()).toUint32() - sub;
  }

  /**
   * @notice Gets the cryptographic sample seed for an epoch
   * @dev Retrieves the randao from the checkpointed randaos mapping using upperLookup.
   *      Then computes the sample seed using keccak256(epoch, randao)
   * @param _epoch The epoch to get the sample seed for
   * @return The sample seed used for validator selection randomness
   */
  function getSampleSeed(Epoch _epoch) internal view returns (uint256) {
    ValidatorSelectionStorage storage store = getStorage();
    uint32 ts = epochToSampleTime(_epoch);
    return uint256(keccak256(abi.encode(_epoch, store.randaos.upperLookup(ts))));
  }

  function getSamplingSize(Epoch _epoch) internal view returns (uint256) {
    uint32 ts = epochToSampleTime(_epoch);
    return StakingLib.getAttesterCountAtTime(Timestamp.wrap(ts));
  }

  function getLagInEpochs() internal view returns (uint256) {
    return getStorage().lagInEpochs;
  }

  /**
   * @notice Gets the validator selection storage struct using EIP-7201 namespaced storage
   * @dev Uses assembly to access storage at the predetermined slot to avoid collisions.
   * @return storageStruct The validator selection storage struct
   */
  function getStorage() internal pure returns (ValidatorSelectionStorage storage storageStruct) {
    bytes32 position = VALIDATOR_SELECTION_STORAGE_POSITION;
    assembly {
      storageStruct.slot := position
    }
  }

  /**
   * @notice Computes the committee index of the proposer for a specific slot
   * @dev Uses keccak256 hash of epoch, slot, and seed to deterministically select a committee member.
   *      The result is modulo committee size to ensure valid index.
   *      The result being modulo biased is not a problem here as the validators in the committee were chosen randomly
   *      and are not ordered.
   * @param _epoch The epoch containing the slot
   * @param _slot The specific slot to compute proposer for
   * @param _seed The epoch's sample seed for randomness
   * @param _size The size of the committee
   * @return The index (0 to _size-1) of the committee member who should propose for this slot
   */
  function computeProposerIndex(Epoch _epoch, Slot _slot, uint256 _seed, uint256 _size) internal pure returns (uint256) {
    return uint256(keccak256(abi.encode(_epoch, _slot, _seed))) % _size;
  }

  /**
   * @notice Samples validator indices for a specific epoch using cryptographic randomness
   * @dev Determines sample timestamp, gets validator set size, and uses SampleLib to select committee indices.
   *      Validates that enough validators are available to meet target committee size.
   * @param _epoch The epoch to sample validators for
   * @param _seed The cryptographic seed for sampling randomness
   * @return sampleTime The timestamp used for validator set sampling
   * @return indices Array of validator indices selected for the committee
   * @custom:reverts Errors.ValidatorSelection__InsufficientValidatorSetSize if not enough validators available
   */
  function sampleValidatorsIndices(Epoch _epoch, uint256 _seed) private returns (uint32, uint256[] memory) {
    ValidatorSelectionStorage storage store = getStorage();
    uint32 ts = epochToSampleTime(_epoch);
    uint256 validatorSetSize = StakingLib.getAttesterCountAtTime(Timestamp.wrap(ts));
    uint256 targetCommitteeSize = store.targetCommitteeSize;

    require(
      validatorSetSize >= targetCommitteeSize,
      Errors.ValidatorSelection__InsufficientValidatorSetSize(validatorSetSize, targetCommitteeSize)
    );

    if (targetCommitteeSize == 0) {
      return (ts, new uint256[](0));
    }

    return (ts, SampleLib.computeCommittee(targetCommitteeSize, validatorSetSize, _seed));
  }

  /**
   * @notice Computes the keccak256 commitment hash for a committee member array
   * @dev Creates a cryptographic commitment to the committee composition that can be verified later.
   *      Used to prevent committee substitution attacks during attestation verification.
   * @param _committee The array of committee member addresses
   * @return The keccak256 hash of the ABI-encoded committee array
   */
  function computeCommitteeCommitment(address[] memory _committee) private pure returns (bytes32) {
    return keccak256(abi.encode(_committee));
  }
}


// File: lib/openzeppelin-contracts/contracts/utils/structs/BitMaps.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (utils/structs/BitMaps.sol)
pragma solidity ^0.8.20;

/**
 * @dev Library for managing uint256 to bool mapping in a compact and efficient way, provided the keys are sequential.
 * Largely inspired by Uniswap's https://github.com/Uniswap/merkle-distributor/blob/master/contracts/MerkleDistributor.sol[merkle-distributor].
 *
 * BitMaps pack 256 booleans across each bit of a single 256-bit slot of `uint256` type.
 * Hence booleans corresponding to 256 _sequential_ indices would only consume a single slot,
 * unlike the regular `bool` which would consume an entire slot for a single value.
 *
 * This results in gas savings in two ways:
 *
 * - Setting a zero value to non-zero only once every 256 times
 * - Accessing the same warm slot for every 256 _sequential_ indices
 */
library BitMaps {
    struct BitMap {
        mapping(uint256 bucket => uint256) _data;
    }

    /**
     * @dev Returns whether the bit at `index` is set.
     */
    function get(BitMap storage bitmap, uint256 index) internal view returns (bool) {
        uint256 bucket = index >> 8;
        uint256 mask = 1 << (index & 0xff);
        return bitmap._data[bucket] & mask != 0;
    }

    /**
     * @dev Sets the bit at `index` to the boolean `value`.
     */
    function setTo(BitMap storage bitmap, uint256 index, bool value) internal {
        if (value) {
            set(bitmap, index);
        } else {
            unset(bitmap, index);
        }
    }

    /**
     * @dev Sets the bit at `index`.
     */
    function set(BitMap storage bitmap, uint256 index) internal {
        uint256 bucket = index >> 8;
        uint256 mask = 1 << (index & 0xff);
        bitmap._data[bucket] |= mask;
    }

    /**
     * @dev Unsets the bit at `index`.
     */
    function unset(BitMap storage bitmap, uint256 index) internal {
        uint256 bucket = index >> 8;
        uint256 mask = 1 << (index & 0xff);
        bitmap._data[bucket] &= ~mask;
    }
}


// File: lib/l1-contracts/src/core/libraries/ConstantsGen.sol
// GENERATED FILE - DO NOT EDIT, RUN yarn remake-constants in yarn-project/constants
// SPDX-License-Identifier: Apache-2.0
// Copyright 2023 Aztec Labs.
pragma solidity >=0.8.27;

/**
 * @title Constants Library
 * @author Aztec Labs
 * @notice Library that contains constants used throughout the Aztec protocol
 */
library Constants {
  // Prime field modulus
  uint256 internal constant P =
    21_888_242_871_839_275_222_246_405_745_257_275_088_548_364_400_416_034_343_698_204_186_575_808_495_617;

  uint256 internal constant MAX_FIELD_VALUE =
    21_888_242_871_839_275_222_246_405_745_257_275_088_548_364_400_416_034_343_698_204_186_575_808_495_616;
  uint256 internal constant L1_TO_L2_MSG_SUBTREE_HEIGHT = 4;
  uint256 internal constant MAX_L2_TO_L1_MSGS_PER_TX = 8;
  uint256 internal constant INITIAL_L2_BLOCK_NUM = 1;
  uint256 internal constant BLOBS_PER_BLOCK = 3;
  uint256 internal constant AZTEC_MAX_EPOCH_DURATION = 48;
  uint256 internal constant GENESIS_ARCHIVE_ROOT =
    14_298_165_331_316_638_916_453_567_345_577_793_920_283_466_066_305_521_584_041_971_978_819_102_601_406;
  uint256 internal constant FEE_JUICE_ADDRESS = 5;
  uint256 internal constant BLS12_POINT_COMPRESSED_BYTES = 48;
  uint256 internal constant PROPOSED_BLOCK_HEADER_LENGTH_BYTES = 284;
  uint256 internal constant ROOT_ROLLUP_PUBLIC_INPUTS_LENGTH = 158;
  uint256 internal constant NUM_MSGS_PER_BASE_PARITY = 4;
  uint256 internal constant NUM_BASE_PARITY_PER_ROOT_PARITY = 4;
}


// File: lib/l1-contracts/src/core/libraries/rollup/RollupOperationsExtLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
// solhint-disable imports-order
pragma solidity >=0.8.27;

import {Errors} from "@aztec/core/libraries/Errors.sol";
import {SubmitEpochRootProofArgs, PublicInputArgs} from "@aztec/core/interfaces/IRollup.sol";
import {STFLib} from "@aztec/core/libraries/rollup/STFLib.sol";
import {Timestamp, TimeLib, Slot, Epoch} from "@aztec/core/libraries/TimeLib.sol";
import {BlobLib} from "@aztec-blob-lib/BlobLib.sol";
import {EpochProofLib} from "./EpochProofLib.sol";
import {AttestationLib} from "@aztec/core/libraries/rollup/AttestationLib.sol";
import {
  ProposeLib, ProposeArgs, CommitteeAttestations, ValidateHeaderArgs, ValidatorSelectionLib
} from "./ProposeLib.sol";
import {Signature} from "@aztec/shared/libraries/SignatureLib.sol";

/**
 * @title RollupOperationsExtLib - External Rollup Library (Proposal and Proof Verification Functions)
 * @author Aztec Labs
 * @notice External library containing proposal-related functions for the Rollup contract to avoid exceeding max
 * contract size.
 *
 * @dev This library serves as an external library for the Rollup contract, splitting off proposal-related
 *      functionality to keep the main contract within the maximum contract size limit. The library contains
 *      external functions primarily focused on:
 *      - Block proposal submission and validation
 *      - Epoch proof submission and verification
 *      - Blob validation and commitment management
 *      - Chain pruning operations
 */
library RollupOperationsExtLib {
  using TimeLib for Timestamp;
  using TimeLib for Slot;
  using AttestationLib for CommitteeAttestations;

  function submitEpochRootProof(SubmitEpochRootProofArgs calldata _args) external {
    EpochProofLib.submitEpochRootProof(_args);
  }

  function validateHeaderWithAttestations(
    ValidateHeaderArgs calldata _args,
    CommitteeAttestations calldata _attestations,
    address[] calldata _signers,
    Signature calldata _attestationsAndSignersSignature
  ) external {
    ProposeLib.validateHeader(_args);
    if (_attestations.isEmpty()) {
      return; // No attestations to validate
    }

    Slot slot = _args.header.slotNumber;
    Epoch epoch = slot.epochFromSlot();
    ValidatorSelectionLib.verifyAttestations(slot, epoch, _attestations, _args.digest);
    ValidatorSelectionLib.verifyProposer(
      slot, epoch, _attestations, _signers, _args.digest, _attestationsAndSignersSignature, false
    );
  }

  function propose(
    ProposeArgs calldata _args,
    CommitteeAttestations memory _attestations,
    address[] calldata _signers,
    Signature calldata _attestationsAndSignersSignature,
    bytes calldata _blobInput,
    bool _checkBlob
  ) external {
    ProposeLib.propose(_args, _attestations, _signers, _attestationsAndSignersSignature, _blobInput, _checkBlob);
  }

  function prune() external {
    require(STFLib.canPruneAtTime(Timestamp.wrap(block.timestamp)), Errors.Rollup__NothingToPrune());
    STFLib.prune();
  }

  function getEpochProofPublicInputs(
    uint256 _start,
    uint256 _end,
    PublicInputArgs calldata _args,
    bytes32[] calldata _fees,
    bytes calldata _blobPublicInputs
  ) external view returns (bytes32[] memory) {
    return EpochProofLib.getEpochProofPublicInputs(_start, _end, _args, _fees, _blobPublicInputs);
  }

  function validateBlobs(bytes calldata _blobsInput, bool _checkBlob)
    external
    view
    returns (bytes32[] memory blobHashes, bytes32 blobsHashesCommitment, bytes[] memory blobCommitments)
  {
    return BlobLib.validateBlobs(_blobsInput, _checkBlob);
  }

  function getBlobBaseFee() external view returns (uint256) {
    return BlobLib.getBlobBaseFee();
  }
}


// File: lib/l1-contracts/src/core/libraries/rollup/ValidatorOperationsExtLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
// solhint-disable imports-order
pragma solidity >=0.8.27;

import {Epoch, Slot, Timestamp, TimeLib} from "@aztec/core/libraries/TimeLib.sol";
import {StakingQueueConfig} from "@aztec/core/libraries/compressed-data/StakingQueueConfig.sol";
import {StakingLib} from "./StakingLib.sol";
import {InvalidateLib} from "./InvalidateLib.sol";
import {ValidatorSelectionLib} from "./ValidatorSelectionLib.sol";
import {CommitteeAttestations} from "@aztec/core/libraries/rollup/AttestationLib.sol";
import {G1Point, G2Point} from "@aztec/shared/libraries/BN254Lib.sol";

/**
 * @title ValidatorOperationsExtLib - External Rollup Library (Validator and Staking Functions)
 * @author Aztec Labs
 * @notice External library containing staking-related functions for the Rollup contract to avoid exceeding max contract
 * size.
 *
 * @dev This library serves as an external library for the Rollup contract, splitting off staking-related
 *      functionality to keep the main contract within the maximum contract size limit. The library contains
 *      external functions primarily focused on:
 *      - Validator staking operations (deposit, withdraw, queue management)
 *      - Validator selection and committee setup
 *      - Block attestation invalidation
 *      - Slashing mechanism integration
 *      - Epoch and proposer management
 */
library ValidatorOperationsExtLib {
  using TimeLib for Timestamp;

  function setSlasher(address _slasher) external {
    StakingLib.setSlasher(_slasher);
  }

  function setLocalEjectionThreshold(uint256 _localEjectionThreshold) external {
    StakingLib.setLocalEjectionThreshold(_localEjectionThreshold);
  }

  function vote(uint256 _proposalId) external {
    StakingLib.vote(_proposalId);
  }

  function deposit(
    address _attester,
    address _withdrawer,
    G1Point memory _publicKeyInG1,
    G2Point memory _publicKeyInG2,
    G1Point memory _proofOfPossession,
    bool _moveWithLatestRollup
  ) external {
    StakingLib.deposit(
      _attester, _withdrawer, _publicKeyInG1, _publicKeyInG2, _proofOfPossession, _moveWithLatestRollup
    );
  }

  function flushEntryQueue(uint256 _toAdd) external {
    StakingLib.flushEntryQueue(_toAdd);
  }

  function initiateWithdraw(address _attester, address _recipient) external returns (bool) {
    return StakingLib.initiateWithdraw(_attester, _recipient);
  }

  function finalizeWithdraw(address _attester) external {
    StakingLib.finalizeWithdraw(_attester);
  }

  function initializeValidatorSelection(uint256 _targetCommitteeSize, uint256 _lagInEpochs) external {
    ValidatorSelectionLib.initialize(_targetCommitteeSize, _lagInEpochs);
  }

  function setupEpoch() external {
    Epoch currentEpoch = Timestamp.wrap(block.timestamp).epochFromTimestamp();
    ValidatorSelectionLib.setupEpoch(currentEpoch);
  }

  function checkpointRandao() external {
    Epoch currentEpoch = Timestamp.wrap(block.timestamp).epochFromTimestamp();
    ValidatorSelectionLib.checkpointRandao(currentEpoch);
  }

  function updateStakingQueueConfig(StakingQueueConfig memory _config) external {
    StakingLib.updateStakingQueueConfig(_config);
  }

  function invalidateBadAttestation(
    uint256 _blockNumber,
    CommitteeAttestations memory _attestations,
    address[] memory _committee,
    uint256 _invalidIndex
  ) external {
    InvalidateLib.invalidateBadAttestation(_blockNumber, _attestations, _committee, _invalidIndex);
  }

  function invalidateInsufficientAttestations(
    uint256 _blockNumber,
    CommitteeAttestations memory _attestations,
    address[] memory _committee
  ) external {
    InvalidateLib.invalidateInsufficientAttestations(_blockNumber, _attestations, _committee);
  }

  function slash(address _attester, uint256 _amount) external returns (bool) {
    return StakingLib.trySlash(_attester, _amount);
  }

  function canProposeAtTime(Timestamp _ts, bytes32 _archive, address _who) external returns (Slot, uint256) {
    return ValidatorSelectionLib.canProposeAtTime(_ts, _archive, _who);
  }

  function getCommitteeAt(Epoch _epoch) external returns (address[] memory) {
    return ValidatorSelectionLib.getCommitteeAt(_epoch);
  }

  function getProposerAt(Slot _slot) external returns (address proposer) {
    (proposer,) = ValidatorSelectionLib.getProposerAt(_slot);
  }

  function getCommitteeCommitmentAt(Epoch _epoch) external returns (bytes32, uint256) {
    return ValidatorSelectionLib.getCommitteeCommitmentAt(_epoch);
  }

  function getSampleSeedAt(Epoch _epoch) external view returns (uint256) {
    return ValidatorSelectionLib.getSampleSeed(_epoch);
  }

  function getSamplingSizeAt(Epoch _epoch) external view returns (uint256) {
    return ValidatorSelectionLib.getSamplingSize(_epoch);
  }

  function getLagInEpochs() external view returns (uint256) {
    return ValidatorSelectionLib.getLagInEpochs();
  }

  function getTargetCommitteeSize() external view returns (uint256) {
    return ValidatorSelectionLib.getStorage().targetCommitteeSize;
  }

  function getEntryQueueFlushSize() external view returns (uint256) {
    uint256 activeAttesterCount = StakingLib.getAttesterCountAtTime(Timestamp.wrap(block.timestamp));
    return StakingLib.getEntryQueueFlushSize(activeAttesterCount);
  }

  function getAvailableValidatorFlushes() external view returns (uint256) {
    return StakingLib.getAvailableValidatorFlushes();
  }
}


// File: lib/l1-contracts/src/core/libraries/rollup/TallySlasherDeploymentExtLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
// solhint-disable imports-order
pragma solidity >=0.8.27;

import {Slasher, ISlasher} from "@aztec/core/slashing/Slasher.sol";
import {TallySlashingProposer} from "@aztec/core/slashing/TallySlashingProposer.sol";

/**
 * @title TallySlasherDeploymentExtLib - External Rollup Library (Tally Slasher Deployment)
 * @author Aztec Labs
 * @notice External library containing tally slasher deployment function for the Rollup contract
 * to avoid exceeding max contract size.
 *
 * @dev This library deploys a tally slasher system using two-phase initialization
 *      to resolve the circular dependency between Slasher and TallySlashingProposer.
 */
library TallySlasherDeploymentExtLib {
  function deployTallySlasher(
    address _rollup,
    address _vetoer,
    address _governance,
    uint256 _quorum,
    uint256 _roundSize,
    uint256 _lifetimeInRounds,
    uint256 _executionDelayInRounds,
    uint256[3] calldata _slashAmounts,
    uint256 _committeeSize,
    uint256 _epochDuration,
    uint256 _slashOffsetInRounds,
    uint256 _slashingDisableDuration
  ) external returns (ISlasher) {
    // Deploy slasher first
    Slasher slasher = new Slasher(_vetoer, _governance, _slashingDisableDuration);

    // Deploy proposer with slasher address
    TallySlashingProposer proposer = new TallySlashingProposer(
      _rollup,
      ISlasher(address(slasher)),
      _quorum,
      _roundSize,
      _lifetimeInRounds,
      _executionDelayInRounds,
      _slashAmounts,
      _committeeSize,
      _epochDuration,
      _slashOffsetInRounds
    );

    // Initialize the slasher with the proposer address
    slasher.initializeProposer(address(proposer));

    return ISlasher(address(slasher));
  }
}


// File: lib/l1-contracts/src/core/libraries/rollup/EmpireSlasherDeploymentExtLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
// solhint-disable imports-order
pragma solidity >=0.8.27;

import {Slasher, ISlasher} from "@aztec/core/slashing/Slasher.sol";
import {EmpireSlashingProposer} from "@aztec/core/slashing/EmpireSlashingProposer.sol";

/**
 * @title EmpireSlasherDeploymentExtLib - External Rollup Library (Empire Slasher Deployment)
 * @author Aztec Labs
 * @notice External library containing empire slasher deployment function for the Rollup contract
 * to avoid exceeding max contract size.
 *
 * @dev This library serves as an external library for the Rollup contract, splitting off empire slasher deployment
 *      functionality to keep the main contract within the maximum contract size limit. Uses two-phase
 *      initialization to resolve circular dependency between Slasher and EmpireSlashingProposer.
 */
library EmpireSlasherDeploymentExtLib {
  function deployEmpireSlasher(
    address _rollup,
    address _vetoer,
    address _governance,
    uint256 _quorumSize,
    uint256 _roundSize,
    uint256 _lifetimeInRounds,
    uint256 _executionDelayInRounds,
    uint256 _slashingDisableDuration
  ) external returns (ISlasher) {
    // Deploy slasher first
    Slasher slasher = new Slasher(_vetoer, _governance, _slashingDisableDuration);

    // Deploy proposer with slasher address
    EmpireSlashingProposer proposer = new EmpireSlashingProposer(
      _rollup, ISlasher(address(slasher)), _quorumSize, _roundSize, _lifetimeInRounds, _executionDelayInRounds
    );

    // Initialize the slasher with the proposer address
    slasher.initializeProposer(address(proposer));

    return ISlasher(address(slasher));
  }
}


// File: lib/l1-contracts/src/core/messagebridge/Inbox.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {IRollup} from "@aztec/core/interfaces/IRollup.sol";
import {IInbox} from "@aztec/core/interfaces/messagebridge/IInbox.sol";
import {Constants} from "@aztec/core/libraries/ConstantsGen.sol";
import {FrontierLib} from "@aztec/core/libraries/crypto/FrontierLib.sol";
import {Hash} from "@aztec/core/libraries/crypto/Hash.sol";
import {DataStructures} from "@aztec/core/libraries/DataStructures.sol";
import {Errors} from "@aztec/core/libraries/Errors.sol";
import {FeeJuicePortal} from "@aztec/core/messagebridge/FeeJuicePortal.sol";
import {IERC20} from "@oz/token/ERC20/IERC20.sol";
import {SafeCast} from "@oz/utils/math/SafeCast.sol";

/**
 * @title Inbox
 * @author Aztec Labs
 * @notice Lives on L1 and is used to pass messages into the rollup, e.g., L1 -> L2 messages.
 */
contract Inbox is IInbox {
  using Hash for DataStructures.L1ToL2Msg;
  using FrontierLib for FrontierLib.Forest;
  using FrontierLib for FrontierLib.Tree;

  address public immutable ROLLUP;
  uint256 public immutable VERSION;
  address public immutable FEE_ASSET_PORTAL;

  uint256 internal immutable HEIGHT;
  uint256 internal immutable SIZE;
  bytes32 internal immutable EMPTY_ROOT; // The root of an empty frontier tree

  // Practically immutable value as we only set it in the constructor.
  FrontierLib.Forest internal forest;

  mapping(uint256 blockNumber => FrontierLib.Tree tree) public trees;

  InboxState internal state;

  constructor(address _rollup, IERC20 _feeAsset, uint256 _version, uint256 _height) {
    ROLLUP = _rollup;
    VERSION = _version;

    HEIGHT = _height;
    SIZE = 2 ** _height;

    state =
      InboxState({rollingHash: 0, totalMessagesInserted: 0, inProgress: uint64(Constants.INITIAL_L2_BLOCK_NUM) + 1});

    forest.initialize(_height);
    EMPTY_ROOT = trees[uint64(Constants.INITIAL_L2_BLOCK_NUM) + 1].root(forest, HEIGHT, SIZE);

    FEE_ASSET_PORTAL = address(new FeeJuicePortal(IRollup(_rollup), _feeAsset, IInbox(this), VERSION));
  }

  /**
   * @notice Inserts a new message into the Inbox
   *
   * @dev Emits `MessageSent` with data for easy access by the sequencer
   *
   * @param _recipient - The recipient of the message
   * @param _content - The content of the message (application specific)
   * @param _secretHash - The secret hash of the message (make it possible to hide when a specific message is consumed
   * on L2)
   *
   * @return Hash of the sent message and its leaf index in the tree.
   */
  function sendL2Message(DataStructures.L2Actor memory _recipient, bytes32 _content, bytes32 _secretHash)
    external
    override(IInbox)
    returns (bytes32, uint256)
  {
    require(uint256(_recipient.actor) <= Constants.MAX_FIELD_VALUE, Errors.Inbox__ActorTooLarge(_recipient.actor));
    require(_recipient.version == VERSION, Errors.Inbox__VersionMismatch(_recipient.version, VERSION));
    require(uint256(_content) <= Constants.MAX_FIELD_VALUE, Errors.Inbox__ContentTooLarge(_content));
    require(uint256(_secretHash) <= Constants.MAX_FIELD_VALUE, Errors.Inbox__SecretHashTooLarge(_secretHash));
    require(IRollup(ROLLUP).getManaTarget() > 0, Errors.Inbox__Ignition());

    // Is this the best way to read a packed struct into local variables in a single SLOAD
    // without having to use assembly and manual unpacking?
    InboxState memory _state = state;
    bytes16 rollingHash = _state.rollingHash;
    uint64 totalMessagesInserted = _state.totalMessagesInserted;
    uint64 inProgress = _state.inProgress;

    FrontierLib.Tree storage currentTree = trees[inProgress];

    if (currentTree.isFull(SIZE)) {
      inProgress += 1;
      currentTree = trees[inProgress];
    }

    // this is the global leaf index and not index in the l2Block subtree
    // such that users can simply use it and don't need access to a node if they are to consume it in public.
    // trees are constant size so global index = tree number * size + subtree index
    uint256 index = (inProgress - Constants.INITIAL_L2_BLOCK_NUM) * SIZE + currentTree.nextIndex;

    // If the sender is the fee asset portal, we use a magic address to simpler have it initialized at genesis.
    // We assume that no-one will know the private key for this address and that the precompile won't change to
    // make calls into arbitrary contracts.
    address senderAddress = msg.sender == FEE_ASSET_PORTAL ? address(uint160(Constants.FEE_JUICE_ADDRESS)) : msg.sender;

    DataStructures.L1ToL2Msg memory message = DataStructures.L1ToL2Msg({
      sender: DataStructures.L1Actor(senderAddress, block.chainid),
      recipient: _recipient,
      content: _content,
      secretHash: _secretHash,
      index: index
    });

    bytes32 leaf = message.sha256ToField();
    currentTree.insertLeaf(leaf);

    bytes16 updatedRollingHash = bytes16(keccak256(abi.encodePacked(rollingHash, leaf)));
    state = InboxState({
      rollingHash: updatedRollingHash,
      totalMessagesInserted: totalMessagesInserted + 1,
      inProgress: inProgress
    });

    emit MessageSent(inProgress, index, leaf, updatedRollingHash);

    return (leaf, index);
  }

  /**
   * @notice Consumes the current tree, and starts a new one if needed
   *
   * @dev Only callable by the rollup contract
   * @dev In the first iteration we return empty tree root because first block's messages tree is always
   * empty because there has to be a 1 block lag to prevent sequencer DOS attacks
   *
   * @param _toConsume - The block number to consume
   *
   * @return The root of the consumed tree
   */
  function consume(uint256 _toConsume) external override(IInbox) returns (bytes32) {
    require(msg.sender == ROLLUP, Errors.Inbox__Unauthorized());

    uint64 inProgress = state.inProgress;
    require(_toConsume < inProgress, Errors.Inbox__MustBuildBeforeConsume());

    bytes32 root = EMPTY_ROOT;
    if (_toConsume > Constants.INITIAL_L2_BLOCK_NUM) {
      root = trees[_toConsume].root(forest, HEIGHT, SIZE);
    }

    // If we are "catching up" we skip the tree creation as it is already there
    if (_toConsume + 1 == inProgress) {
      state.inProgress = inProgress + 1;
    }

    return root;
  }

  /**
   * @notice Catch up the inbox to the pending block number
   *
   * @dev Only callable by the rollup contract
   *      Will only be called WHEN a change is made from 0 to non-zero mana limits
   *
   * @param _pendingBlockNumber - The pending block number to catch up to
   */
  function catchUp(uint256 _pendingBlockNumber) external override(IInbox) {
    require(msg.sender == ROLLUP, Errors.Inbox__Unauthorized());
    // The next expected will be 1 ahead of the next block, e.g., + 2 from current.
    state.inProgress = SafeCast.toUint64(_pendingBlockNumber + 2);
    emit InboxSynchronized(state.inProgress);
  }

  function getFeeAssetPortal() external view override(IInbox) returns (address) {
    return FEE_ASSET_PORTAL;
  }

  function getRoot(uint256 _blockNumber) external view override(IInbox) returns (bytes32) {
    return trees[_blockNumber].root(forest, HEIGHT, SIZE);
  }

  function getState() external view override(IInbox) returns (InboxState memory) {
    return state;
  }

  function getTotalMessagesInserted() external view override(IInbox) returns (uint64) {
    return state.totalMessagesInserted;
  }

  function getInProgress() external view override(IInbox) returns (uint64) {
    return state.inProgress;
  }
}


// File: lib/l1-contracts/src/core/messagebridge/Outbox.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {IRollup} from "@aztec/core/interfaces/IRollup.sol";
import {IOutbox} from "@aztec/core/interfaces/messagebridge/IOutbox.sol";
import {Hash} from "@aztec/core/libraries/crypto/Hash.sol";
import {MerkleLib} from "@aztec/core/libraries/crypto/MerkleLib.sol";
import {DataStructures} from "@aztec/core/libraries/DataStructures.sol";
import {Errors} from "@aztec/core/libraries/Errors.sol";
import {BitMaps} from "@oz/utils/structs/BitMaps.sol";

/**
 * @title Outbox
 * @author Aztec Labs
 * @notice Lives on L1 and is used to consume L2 -> L1 messages. Messages are inserted by the Rollup
 * and will be consumed by the portal contracts.
 */
contract Outbox is IOutbox {
  using Hash for DataStructures.L2ToL1Msg;
  using BitMaps for BitMaps.BitMap;

  struct RootData {
    // This is the outhash specified by header.globalvariables.outHash of any given block.
    bytes32 root;
    BitMaps.BitMap nullified;
  }

  IRollup public immutable ROLLUP;
  uint256 public immutable VERSION;
  mapping(uint256 l2BlockNumber => RootData root) internal roots;

  constructor(address _rollup, uint256 _version) {
    ROLLUP = IRollup(_rollup);
    VERSION = _version;
  }

  /**
   * @notice Inserts the root of a merkle tree containing all of the L2 to L1 messages in a block
   *
   * @dev Only callable by the rollup contract
   * @dev Emits `RootAdded` upon inserting the root successfully
   *
   * @param _l2BlockNumber - The L2 Block Number in which the L2 to L1 messages reside
   * @param _root - The merkle root of the tree where all the L2 to L1 messages are leaves
   */
  function insert(uint256 _l2BlockNumber, bytes32 _root) external override(IOutbox) {
    require(msg.sender == address(ROLLUP), Errors.Outbox__Unauthorized());
    require(_l2BlockNumber > ROLLUP.getProvenBlockNumber(), Errors.Outbox__BlockAlreadyProven(_l2BlockNumber));

    roots[_l2BlockNumber].root = _root;

    emit RootAdded(_l2BlockNumber, _root);
  }

  /**
   * @notice Consumes an entry from the Outbox
   *
   * @dev Only useable by portals / recipients of messages
   * @dev Emits `MessageConsumed` when consuming messages
   *
   * @param _message - The L2 to L1 message
   * @param _l2BlockNumber - The block number specifying the block that contains the message we want to consume
   * @param _leafIndex - The index inside the merkle tree where the message is located
   * @param _path - The sibling path used to prove inclusion of the message, the _path length directly depends
   * on the total amount of L2 to L1 messages in the block. i.e. the length of _path is equal to the depth of the
   * L1 to L2 message tree.
   */
  function consume(
    DataStructures.L2ToL1Msg calldata _message,
    uint256 _l2BlockNumber,
    uint256 _leafIndex,
    bytes32[] calldata _path
  ) external override(IOutbox) {
    require(_path.length < 256, Errors.Outbox__PathTooLong());
    require(_leafIndex < (1 << _path.length), Errors.Outbox__LeafIndexOutOfBounds(_leafIndex, _path.length));
    require(_l2BlockNumber <= ROLLUP.getProvenBlockNumber(), Errors.Outbox__BlockNotProven(_l2BlockNumber));
    require(_message.sender.version == VERSION, Errors.Outbox__VersionMismatch(_message.sender.version, VERSION));

    require(
      msg.sender == _message.recipient.actor, Errors.Outbox__InvalidRecipient(_message.recipient.actor, msg.sender)
    );

    require(block.chainid == _message.recipient.chainId, Errors.Outbox__InvalidChainId());

    RootData storage rootData = roots[_l2BlockNumber];

    bytes32 blockRoot = rootData.root;

    require(blockRoot != bytes32(0), Errors.Outbox__NothingToConsumeAtBlock(_l2BlockNumber));

    uint256 leafId = (1 << _path.length) + _leafIndex;

    require(!rootData.nullified.get(leafId), Errors.Outbox__AlreadyNullified(_l2BlockNumber, leafId));

    bytes32 messageHash = _message.sha256ToField();

    MerkleLib.verifyMembership(_path, messageHash, _leafIndex, blockRoot);

    rootData.nullified.set(leafId);

    emit MessageConsumed(_l2BlockNumber, blockRoot, messageHash, leafId);
  }

  /**
   * @notice Checks to see if an L2 to L1 message in a specific block has been consumed
   *
   * @dev - This function does not throw. Out-of-bounds access is considered valid, but will always return false
   *
   * @param _l2BlockNumber - The block number specifying the block that contains the message we want to check
   * @param _leafId - The unique id of the message leaf
   *
   * @return bool - True if the message has been consumed, false otherwise
   */
  function hasMessageBeenConsumedAtBlock(uint256 _l2BlockNumber, uint256 _leafId)
    external
    view
    override(IOutbox)
    returns (bool)
  {
    return roots[_l2BlockNumber].nullified.get(_leafId);
  }

  /**
   * @notice  Fetch the root data for a given block number
   *          Returns (0, 0) if the block is not proven
   *
   * @param _l2BlockNumber - The block number to fetch the root data for
   *
   * @return bytes32 - The root of the merkle tree containing the L2 to L1 messages
   */
  function getRootData(uint256 _l2BlockNumber) external view override(IOutbox) returns (bytes32) {
    if (_l2BlockNumber > ROLLUP.getProvenBlockNumber()) {
      return bytes32(0);
    }
    RootData storage rootData = roots[_l2BlockNumber];
    return rootData.root;
  }
}


// File: lib/l1-contracts/src/core/slashing/Slasher.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {ISlasher} from "@aztec/core/interfaces/ISlasher.sol";
import {IPayload} from "@aztec/governance/interfaces/IPayload.sol";

contract Slasher is ISlasher {
  address public immutable GOVERNANCE;
  address public immutable VETOER;
  uint256 public immutable SLASHING_DISABLE_DURATION;
  // solhint-disable-next-line var-name-mixedcase
  address public PROPOSER;

  uint256 public slashingDisabledUntil = 0;

  mapping(address payload => bool vetoed) public vetoedPayloads;

  error Slasher__SlashFailed(address target, bytes data, bytes returnData);
  error Slasher__CallerNotAuthorizedToSlash(address caller);
  error Slasher__CallerNotVetoer(address caller, address vetoer);
  error Slasher__PayloadVetoed(address payload);
  error Slasher__AlreadyInitialized();
  error Slasher__ProposerZeroAddress();
  error Slasher__SlashingDisabled();

  constructor(address _vetoer, address _governance, uint256 _slashingDisableDuration) {
    GOVERNANCE = _governance;
    VETOER = _vetoer;
    SLASHING_DISABLE_DURATION = _slashingDisableDuration;
  }

  // solhint-disable-next-line comprehensive-interface
  function initializeProposer(address _proposer) external {
    require(PROPOSER == address(0), Slasher__AlreadyInitialized());
    require(_proposer != address(0), Slasher__ProposerZeroAddress());
    PROPOSER = _proposer;
  }

  function vetoPayload(IPayload _payload) external override(ISlasher) returns (bool) {
    require(msg.sender == VETOER, Slasher__CallerNotVetoer(msg.sender, VETOER));
    vetoedPayloads[address(_payload)] = true;
    emit VetoedPayload(address(_payload));
    return true;
  }

  function setSlashingEnabled(bool _enabled) external override(ISlasher) {
    require(msg.sender == VETOER, Slasher__CallerNotVetoer(msg.sender, VETOER));
    if (!_enabled) {
      slashingDisabledUntil = block.timestamp + SLASHING_DISABLE_DURATION;
    } else {
      slashingDisabledUntil = 0;
    }
    emit SlashingDisabled(slashingDisabledUntil);
  }

  function slash(IPayload _payload) external override(ISlasher) returns (bool) {
    require(msg.sender == PROPOSER || msg.sender == GOVERNANCE, Slasher__CallerNotAuthorizedToSlash(msg.sender));
    require(block.timestamp >= slashingDisabledUntil, Slasher__SlashingDisabled());
    require(!vetoedPayloads[address(_payload)], Slasher__PayloadVetoed(address(_payload)));

    IPayload.Action[] memory actions = _payload.getActions();
    for (uint256 i = 0; i < actions.length; i++) {
      (bool success, bytes memory returnData) = actions[i].target.call(actions[i].data);
      require(success, Slasher__SlashFailed(actions[i].target, actions[i].data, returnData));
    }

    return true;
  }

  function isSlashingEnabled() external view override(ISlasher) returns (bool) {
    return block.timestamp >= slashingDisabledUntil;
  }
}


// File: lib/openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.3.0) (utils/cryptography/EIP712.sol)

pragma solidity ^0.8.20;

import {MessageHashUtils} from "./MessageHashUtils.sol";
import {ShortStrings, ShortString} from "../ShortStrings.sol";
import {IERC5267} from "../../interfaces/IERC5267.sol";

/**
 * @dev https://eips.ethereum.org/EIPS/eip-712[EIP-712] is a standard for hashing and signing of typed structured data.
 *
 * The encoding scheme specified in the EIP requires a domain separator and a hash of the typed structured data, whose
 * encoding is very generic and therefore its implementation in Solidity is not feasible, thus this contract
 * does not implement the encoding itself. Protocols need to implement the type-specific encoding they need in order to
 * produce the hash of their typed data using a combination of `abi.encode` and `keccak256`.
 *
 * This contract implements the EIP-712 domain separator ({_domainSeparatorV4}) that is used as part of the encoding
 * scheme, and the final step of the encoding to obtain the message digest that is then signed via ECDSA
 * ({_hashTypedDataV4}).
 *
 * The implementation of the domain separator was designed to be as efficient as possible while still properly updating
 * the chain id to protect against replay attacks on an eventual fork of the chain.
 *
 * NOTE: This contract implements the version of the encoding known as "v4", as implemented by the JSON RPC method
 * https://docs.metamask.io/guide/signing-data.html[`eth_signTypedDataV4` in MetaMask].
 *
 * NOTE: In the upgradeable version of this contract, the cached values will correspond to the address, and the domain
 * separator of the implementation contract. This will cause the {_domainSeparatorV4} function to always rebuild the
 * separator from the immutable values, which is cheaper than accessing a cached version in cold storage.
 *
 * @custom:oz-upgrades-unsafe-allow state-variable-immutable
 */
abstract contract EIP712 is IERC5267 {
    using ShortStrings for *;

    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // Cache the domain separator as an immutable value, but also store the chain id that it corresponds to, in order to
    // invalidate the cached domain separator if the chain id changes.
    bytes32 private immutable _cachedDomainSeparator;
    uint256 private immutable _cachedChainId;
    address private immutable _cachedThis;

    bytes32 private immutable _hashedName;
    bytes32 private immutable _hashedVersion;

    ShortString private immutable _name;
    ShortString private immutable _version;
    // slither-disable-next-line constable-states
    string private _nameFallback;
    // slither-disable-next-line constable-states
    string private _versionFallback;

    /**
     * @dev Initializes the domain separator and parameter caches.
     *
     * The meaning of `name` and `version` is specified in
     * https://eips.ethereum.org/EIPS/eip-712#definition-of-domainseparator[EIP-712]:
     *
     * - `name`: the user readable name of the signing domain, i.e. the name of the DApp or the protocol.
     * - `version`: the current major version of the signing domain.
     *
     * NOTE: These parameters cannot be changed except through a xref:learn::upgrading-smart-contracts.adoc[smart
     * contract upgrade].
     */
    constructor(string memory name, string memory version) {
        _name = name.toShortStringWithFallback(_nameFallback);
        _version = version.toShortStringWithFallback(_versionFallback);
        _hashedName = keccak256(bytes(name));
        _hashedVersion = keccak256(bytes(version));

        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator();
        _cachedThis = address(this);
    }

    /**
     * @dev Returns the domain separator for the current chain.
     */
    function _domainSeparatorV4() internal view returns (bytes32) {
        if (address(this) == _cachedThis && block.chainid == _cachedChainId) {
            return _cachedDomainSeparator;
        } else {
            return _buildDomainSeparator();
        }
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(TYPE_HASH, _hashedName, _hashedVersion, block.chainid, address(this)));
    }

    /**
     * @dev Given an already https://eips.ethereum.org/EIPS/eip-712#definition-of-hashstruct[hashed struct], this
     * function returns the hash of the fully encoded EIP712 message for this domain.
     *
     * This hash can be used together with {ECDSA-recover} to obtain the signer of a message. For example:
     *
     * ```solidity
     * bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
     *     keccak256("Mail(address to,string contents)"),
     *     mailTo,
     *     keccak256(bytes(mailContents))
     * )));
     * address signer = ECDSA.recover(digest, signature);
     * ```
     */
    function _hashTypedDataV4(bytes32 structHash) internal view virtual returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), structHash);
    }

    /**
     * @inheritdoc IERC5267
     */
    function eip712Domain()
        public
        view
        virtual
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (
            hex"0f", // 01111
            _EIP712Name(),
            _EIP712Version(),
            block.chainid,
            address(this),
            bytes32(0),
            new uint256[](0)
        );
    }

    /**
     * @dev The name parameter for the EIP712 domain.
     *
     * NOTE: By default this function reads _name which is an immutable value.
     * It only reads from storage if necessary (in case the value is too large to fit in a ShortString).
     */
    // solhint-disable-next-line func-name-mixedcase
    function _EIP712Name() internal view returns (string memory) {
        return _name.toStringWithFallback(_nameFallback);
    }

    /**
     * @dev The version parameter for the EIP712 domain.
     *
     * NOTE: By default this function reads _version which is an immutable value.
     * It only reads from storage if necessary (in case the value is too large to fit in a ShortString).
     */
    // solhint-disable-next-line func-name-mixedcase
    function _EIP712Version() internal view returns (string memory) {
        return _version.toStringWithFallback(_versionFallback);
    }
}


// File: lib/l1-contracts/src/core/libraries/rollup/RewardExtLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {RewardLib, RewardConfig} from "@aztec/core/libraries/rollup/RewardLib.sol";
import {Epoch, Timestamp} from "@aztec/core/libraries/TimeLib.sol";

import {
  RewardBooster,
  RewardBoostConfig,
  IBoosterCore,
  IValidatorSelection
} from "@aztec/core/reward-boost/RewardBooster.sol";

library RewardExtLib {
  function initialize(Timestamp _earliestRewardsClaimableTimestamp) external {
    RewardLib.initialize(_earliestRewardsClaimableTimestamp);
  }

  function setConfig(RewardConfig memory _config) external {
    RewardLib.setConfig(_config);
  }

  function setIsRewardsClaimable(bool _isRewardsClaimable) external {
    RewardLib.setIsRewardsClaimable(_isRewardsClaimable);
  }

  function claimSequencerRewards(address _sequencer) external returns (uint256) {
    return RewardLib.claimSequencerRewards(_sequencer);
  }

  function claimProverRewards(address _prover, Epoch[] memory _epochs) external returns (uint256) {
    return RewardLib.claimProverRewards(_prover, _epochs);
  }

  function deployRewardBooster(RewardBoostConfig memory _config) external returns (IBoosterCore) {
    RewardBooster booster = new RewardBooster(IValidatorSelection(address(this)), _config);
    return IBoosterCore(address(booster));
  }
}


// File: lib/l1-contracts/src/core/libraries/DataStructures.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

/**
 * @title Data Structures Library
 * @author Aztec Labs
 * @notice Library that contains data structures used throughout the Aztec protocol
 */
library DataStructures {
  // docs:start:l1_actor
  /**
   * @notice Actor on L1.
   * @param actor - The address of the actor
   * @param chainId - The chainId of the actor
   */
  struct L1Actor {
    address actor;
    uint256 chainId;
  }
  // docs:end:l1_actor

  // docs:start:l2_actor
  /**
   * @notice Actor on L2.
   * @param actor - The aztec address of the actor
   * @param version - Ahe Aztec instance the actor is on
   */
  struct L2Actor {
    bytes32 actor;
    uint256 version;
  }
  // docs:end:l2_actor

  // docs:start:l1_to_l2_msg
  /**
   * @notice Struct containing a message from L1 to L2
   * @param sender - The sender of the message
   * @param recipient - The recipient of the message
   * @param content - The content of the message (application specific) padded to bytes32 or hashed if larger.
   * @param secretHash - The secret hash of the message (make it possible to hide when a specific message is consumed on
   * L2).
   * @param index - Global leaf index on the L1 to L2 messages tree.
   */
  struct L1ToL2Msg {
    L1Actor sender;
    L2Actor recipient;
    bytes32 content;
    bytes32 secretHash;
    uint256 index;
  }
  // docs:end:l1_to_l2_msg

  // docs:start:l2_to_l1_msg
  /**
   * @notice Struct containing a message from L2 to L1
   * @param sender - The sender of the message
   * @param recipient - The recipient of the message
   * @param content - The content of the message (application specific) padded to bytes32 or hashed if larger.
   * @dev Not to be confused with L2ToL1Message in Noir circuits
   */
  struct L2ToL1Msg {
    DataStructures.L2Actor sender;
    DataStructures.L1Actor recipient;
    bytes32 content;
  }
  // docs:end:l2_to_l1_msg
}


// File: lib/openzeppelin-contracts/contracts/utils/Panic.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (utils/Panic.sol)

pragma solidity ^0.8.20;

/**
 * @dev Helper library for emitting standardized panic codes.
 *
 * ```solidity
 * contract Example {
 *      using Panic for uint256;
 *
 *      // Use any of the declared internal constants
 *      function foo() { Panic.GENERIC.panic(); }
 *
 *      // Alternatively
 *      function foo() { Panic.panic(Panic.GENERIC); }
 * }
 * ```
 *
 * Follows the list from https://github.com/ethereum/solidity/blob/v0.8.24/libsolutil/ErrorCodes.h[libsolutil].
 *
 * _Available since v5.1._
 */
// slither-disable-next-line unused-state
library Panic {
    /// @dev generic / unspecified error
    uint256 internal constant GENERIC = 0x00;
    /// @dev used by the assert() builtin
    uint256 internal constant ASSERT = 0x01;
    /// @dev arithmetic underflow or overflow
    uint256 internal constant UNDER_OVERFLOW = 0x11;
    /// @dev division or modulo by zero
    uint256 internal constant DIVISION_BY_ZERO = 0x12;
    /// @dev enum conversion error
    uint256 internal constant ENUM_CONVERSION_ERROR = 0x21;
    /// @dev invalid encoding in storage
    uint256 internal constant STORAGE_ENCODING_ERROR = 0x22;
    /// @dev empty array pop
    uint256 internal constant EMPTY_ARRAY_POP = 0x31;
    /// @dev array out of bounds access
    uint256 internal constant ARRAY_OUT_OF_BOUNDS = 0x32;
    /// @dev resource error (too large allocation or too large array)
    uint256 internal constant RESOURCE_ERROR = 0x41;
    /// @dev calling invalid internal function
    uint256 internal constant INVALID_INTERNAL_FUNCTION = 0x51;

    /// @dev Reverts with a panic code. Recommended to use with
    /// the internal constants with predefined codes.
    function panic(uint256 code) internal pure {
        assembly ("memory-safe") {
            mstore(0x00, 0x4e487b71)
            mstore(0x20, code)
            revert(0x1c, 0x24)
        }
    }
}


// File: lib/l1-contracts/src/core/libraries/SlashRoundLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {SafeCast} from "@oz/utils/math/SafeCast.sol";

type SlashRound is uint256;

function addSlashRound(SlashRound _a, SlashRound _b) pure returns (SlashRound) {
  return SlashRound.wrap(SlashRound.unwrap(_a) + SlashRound.unwrap(_b));
}

function subSlashRound(SlashRound _a, SlashRound _b) pure returns (SlashRound) {
  return SlashRound.wrap(SlashRound.unwrap(_a) - SlashRound.unwrap(_b));
}

function eqSlashRound(SlashRound _a, SlashRound _b) pure returns (bool) {
  return SlashRound.unwrap(_a) == SlashRound.unwrap(_b);
}

function neqSlashRound(SlashRound _a, SlashRound _b) pure returns (bool) {
  return SlashRound.unwrap(_a) != SlashRound.unwrap(_b);
}

function ltSlashRound(SlashRound _a, SlashRound _b) pure returns (bool) {
  return SlashRound.unwrap(_a) < SlashRound.unwrap(_b);
}

function lteSlashRound(SlashRound _a, SlashRound _b) pure returns (bool) {
  return SlashRound.unwrap(_a) <= SlashRound.unwrap(_b);
}

function gtSlashRound(SlashRound _a, SlashRound _b) pure returns (bool) {
  return SlashRound.unwrap(_a) > SlashRound.unwrap(_b);
}

function gteSlashRound(SlashRound _a, SlashRound _b) pure returns (bool) {
  return SlashRound.unwrap(_a) >= SlashRound.unwrap(_b);
}

using {
  addSlashRound as +,
  subSlashRound as -,
  eqSlashRound as ==,
  neqSlashRound as !=,
  ltSlashRound as <,
  lteSlashRound as <=,
  gtSlashRound as >,
  gteSlashRound as >=
} for SlashRound global;

type CompressedSlashRound is uint32;

library CompressedSlashRoundMath {
  function compress(SlashRound _round) internal pure returns (CompressedSlashRound) {
    return CompressedSlashRound.wrap(SafeCast.toUint32(SlashRound.unwrap(_round)));
  }

  function decompress(CompressedSlashRound _round) internal pure returns (SlashRound) {
    return SlashRound.wrap(uint256(CompressedSlashRound.unwrap(_round)));
  }
}


// File: lib/l1-contracts/src/governance/libraries/CheckpointedUintLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {Errors} from "@aztec/governance/libraries/Errors.sol";
import {Timestamp} from "@aztec/shared/libraries/TimeMath.sol";
import {SafeCast} from "@oz/utils/math/SafeCast.sol";
import {Checkpoints} from "@oz/utils/structs/Checkpoints.sol";

/**
 * @title CheckpointedUintLib
 * @notice  Library for managing Trace224 using a timestamp as key,
 *          Provides helper functions to `add` to or `sub` from the current value.
 */
library CheckpointedUintLib {
  using Checkpoints for Checkpoints.Trace224;
  using SafeCast for uint256;

  /**
   * @notice  Add `_amount` to the current value
   *
   * @dev   The amounts are cast to uint224 before storing such that the (key: value) fits in a single slot
   *
   * @param _self - The Trace224 to add to
   * @param _amount - The amount to add
   *
   * @return - The current value and the new value
   */
  function add(Checkpoints.Trace224 storage _self, uint256 _amount) internal returns (uint256, uint256) {
    uint224 current = _self.latest();
    if (_amount == 0) {
      return (current, current);
    }
    uint224 amount = _amount.toUint224();
    _self.push(block.timestamp.toUint32(), current + amount);
    return (current, current + amount);
  }

  /**
   * @notice  Subtract `_amount` from the current value
   *
   * @param _self - The Trace224 to subtract from
   * @param _amount - The amount to subtract
   * @return - The current value and the new value
   */
  function sub(Checkpoints.Trace224 storage _self, uint256 _amount) internal returns (uint256, uint256) {
    uint224 current = _self.latest();
    if (_amount == 0) {
      return (current, current);
    }
    uint224 amount = _amount.toUint224();
    require(current >= amount, Errors.Governance__CheckpointedUintLib__InsufficientValue(msg.sender, current, amount));
    _self.push(block.timestamp.toUint32(), current - amount);
    return (current, current - amount);
  }

  /**
   * @notice  Get the current value
   *
   * @param _self - The Trace224 to get the value of
   * @return - The current value
   */
  function valueNow(Checkpoints.Trace224 storage _self) internal view returns (uint256) {
    return _self.latest();
  }

  /**
   * @notice  Get the value at a given timestamp
   *          The timestamp MUST be in the past to guarantee it is stable
   *
   * @dev     Uses `upperLookupRecent` instead of just `upperLookup` as it will most
   *          likely be a recent value when looked up as part of governance.
   *
   * @param _self - The Trace224 to get the value of
   * @param _time - The timestamp to get the value at
   * @return - The value at the given timestamp
   */
  function valueAt(Checkpoints.Trace224 storage _self, Timestamp _time) internal view returns (uint256) {
    require(_time < Timestamp.wrap(block.timestamp), Errors.Governance__CheckpointedUintLib__NotInPast());
    return _self.upperLookupRecent(Timestamp.unwrap(_time).toUint32());
  }
}


// File: lib/l1-contracts/src/governance/libraries/compressed-data/Ballot.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {SafeCast} from "@oz/utils/math/SafeCast.sol";

struct Ballot {
  uint256 yea;
  uint256 nay;
}

type CompressedBallot is uint256;

library BallotLib {
  using SafeCast for uint256;

  uint256 internal constant YEA_MASK = 0xffffffffffffffffffffffffffffffff00000000000000000000000000000000;
  uint256 internal constant NAY_MASK = 0xffffffffffffffffffffffffffffffff;

  function getYea(CompressedBallot _compressedBallot) internal pure returns (uint256) {
    return CompressedBallot.unwrap(_compressedBallot) >> 128;
  }

  function getNay(CompressedBallot _compressedBallot) internal pure returns (uint256) {
    return CompressedBallot.unwrap(_compressedBallot) & NAY_MASK;
  }

  function updateYea(CompressedBallot _compressedBallot, uint256 _yea) internal pure returns (CompressedBallot) {
    uint256 value = CompressedBallot.unwrap(_compressedBallot) & ~YEA_MASK;
    return CompressedBallot.wrap(value | (_yea << 128));
  }

  function updateNay(CompressedBallot _compressedBallot, uint256 _nay) internal pure returns (CompressedBallot) {
    uint256 value = CompressedBallot.unwrap(_compressedBallot) & ~NAY_MASK;
    return CompressedBallot.wrap(value | _nay);
  }

  function addYea(CompressedBallot _compressedBallot, uint256 _amount) internal pure returns (CompressedBallot) {
    uint256 currentYea = getYea(_compressedBallot);
    uint256 newYea = currentYea + _amount;
    return updateYea(_compressedBallot, newYea.toUint128());
  }

  function addNay(CompressedBallot _compressedBallot, uint256 _amount) internal pure returns (CompressedBallot) {
    uint256 currentNay = getNay(_compressedBallot);
    uint256 newNay = currentNay + _amount;
    return updateNay(_compressedBallot, newNay.toUint128());
  }

  function compress(Ballot memory _ballot) internal pure returns (CompressedBallot) {
    // We are doing cast to uint128 but inside a uint256 to not wreck the shifting.
    uint256 yea = _ballot.yea.toUint128();
    uint256 nay = _ballot.nay.toUint128();
    return CompressedBallot.wrap((yea << 128) | nay);
  }

  function decompress(CompressedBallot _compressedBallot) internal pure returns (Ballot memory) {
    return Ballot({yea: getYea(_compressedBallot), nay: getNay(_compressedBallot)});
  }
}


// File: lib/l1-contracts/src/governance/libraries/compressed-data/Configuration.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {Configuration, ProposeWithLockConfiguration} from "@aztec/governance/interfaces/IGovernance.sol";
import {CompressedTimestamp, CompressedTimeMath} from "@aztec/shared/libraries/CompressedTimeMath.sol";
import {Timestamp} from "@aztec/shared/libraries/TimeMath.sol";
import {SafeCast} from "@oz/utils/math/SafeCast.sol";

/**
 * @title CompressedConfiguration
 * @notice Compressed storage representation of governance configuration
 * @dev Packs configuration into minimal storage slots:
 *      Slot 1: Timing & percentages - votingDelay (32), votingDuration (32), executionDelay (32), gracePeriod (32),
 * quorum (64), requiredYeaMargin (64)
 *      Slot 2: Amounts & proposeConfig - minimumVotes (96), lockAmount (96), lockDelay (32), unused (32)
 *
 * This packing reduces storage from ~8 slots to 2 slots.
 * All timestamps use CompressedTimestamp (uint32, valid until year 2106).
 * Percentages (quorum, requiredYeaMargin) use uint64 (max 1e18).
 * Amounts use uint96 for realistic token amounts.
 * ProposeConfig fields are kept together in Slot 2.
 */
struct CompressedConfiguration {
  // Slot 1: Timing and percentages - 32*4 + 64*2 = 256 bits
  CompressedTimestamp votingDelay;
  CompressedTimestamp votingDuration;
  CompressedTimestamp executionDelay;
  CompressedTimestamp gracePeriod;
  uint64 quorum;
  uint64 requiredYeaMargin;
  // Slot 2: Amounts and proposeConfig - 96 + 96 + 32 = 224 bits (32 bits unused)
  uint96 minimumVotes;
  uint96 lockAmount;
  CompressedTimestamp lockDelay;
}

library CompressedConfigurationLib {
  using SafeCast for uint256;
  using CompressedTimeMath for Timestamp;
  using CompressedTimeMath for CompressedTimestamp;

  /**
   * @notice Get the propose configuration directly from storage
   * @param _compressed Storage pointer to compressed configuration
   * @return The propose configuration
   */
  function getProposeConfig(CompressedConfiguration storage _compressed)
    internal
    view
    returns (ProposeWithLockConfiguration memory)
  {
    return
      ProposeWithLockConfiguration({lockDelay: _compressed.lockDelay.decompress(), lockAmount: _compressed.lockAmount});
  }

  /**
   * @notice Compress a Configuration struct into CompressedConfiguration
   * @param _config The uncompressed configuration
   * @return The compressed configuration
   * @dev Values that exceed the compressed type limits will cause a revert.
   *      This is intentional to prevent storing invalid configurations.
   */
  function compress(Configuration memory _config) internal pure returns (CompressedConfiguration memory) {
    // Validate that amounts fit in their compressed types
    require(_config.proposeConfig.lockAmount <= type(uint96).max, "lockAmount exceeds uint96");
    require(_config.minimumVotes <= type(uint96).max, "minimumVotes exceeds uint96");
    require(_config.quorum <= type(uint64).max, "quorum exceeds uint64");
    require(_config.requiredYeaMargin <= type(uint64).max, "requiredYeaMargin exceeds uint64");

    return CompressedConfiguration({
      votingDelay: _config.votingDelay.compress(),
      votingDuration: _config.votingDuration.compress(),
      executionDelay: _config.executionDelay.compress(),
      gracePeriod: _config.gracePeriod.compress(),
      quorum: _config.quorum.toUint64(),
      requiredYeaMargin: _config.requiredYeaMargin.toUint64(),
      minimumVotes: _config.minimumVotes.toUint96(),
      lockAmount: _config.proposeConfig.lockAmount.toUint96(),
      lockDelay: _config.proposeConfig.lockDelay.compress()
    });
  }

  /**
   * @notice Decompress a CompressedConfiguration into Configuration
   * @param _compressed The compressed configuration
   * @return The uncompressed configuration
   */
  function decompress(CompressedConfiguration memory _compressed) internal pure returns (Configuration memory) {
    return Configuration({
      proposeConfig: ProposeWithLockConfiguration({
        lockDelay: _compressed.lockDelay.decompress(),
        lockAmount: _compressed.lockAmount
      }),
      votingDelay: _compressed.votingDelay.decompress(),
      votingDuration: _compressed.votingDuration.decompress(),
      executionDelay: _compressed.executionDelay.decompress(),
      gracePeriod: _compressed.gracePeriod.decompress(),
      quorum: _compressed.quorum,
      requiredYeaMargin: _compressed.requiredYeaMargin,
      minimumVotes: _compressed.minimumVotes
    });
  }
}


// File: lib/l1-contracts/src/governance/libraries/compressed-data/Proposal.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {Proposal, ProposalState, ProposalConfiguration} from "@aztec/governance/interfaces/IGovernance.sol";
import {IPayload} from "@aztec/governance/interfaces/IPayload.sol";
import {CompressedBallot, BallotLib} from "@aztec/governance/libraries/compressed-data/Ballot.sol";
import {CompressedConfiguration} from "@aztec/governance/libraries/compressed-data/Configuration.sol";
import {CompressedTimestamp, CompressedTimeMath} from "@aztec/shared/libraries/CompressedTimeMath.sol";
import {Timestamp} from "@aztec/shared/libraries/TimeMath.sol";
import {SafeCast} from "@oz/utils/math/SafeCast.sol";

/**
 * @title CompressedProposal
 * @notice Compressed storage representation of governance proposals
 * @dev Packs proposal data with embedded config values into 4 storage slots:
 *      Slot 1: proposer (160) + minimumVotes (96) = 256 bits
 *      Slot 2: cachedState (8) + creation (32) + timing fields (32*4) + quorum (64) = 232 bits
 *      Slot 3: summedBallot (256 bits as CompressedBallot)
 *      Slot 4: payload (160) + requiredYeaMargin (64) = 224 bits
 *
 * This packing reduces storage from ~10 slots to 4 slots by embedding config values
 * directly instead of storing the entire configuration struct.
 */
struct CompressedProposal {
  // Slot 1: Core Identity (256 bits)
  address proposer; // 160 bits
  uint96 minimumVotes; // 96 bits - from config
  // Slot 2: Timing (232 bits used, 24 bits padding)
  ProposalState cachedState; // 8 bits
  CompressedTimestamp creation; // 32 bits
  CompressedTimestamp votingDelay; // 32 bits - from config
  CompressedTimestamp votingDuration; // 32 bits - from config
  CompressedTimestamp executionDelay; // 32 bits - from config
  CompressedTimestamp gracePeriod; // 32 bits - from config
  uint64 quorum; // 64 bits - from config
  // Slot 3: Votes (256 bits)
  CompressedBallot summedBallot; // 256 bits (128 yea + 128 nay)
  // Slot 4: References (224 bits used, 32 bits padding)
  IPayload payload; // 160 bits
  uint64 requiredYeaMargin; // 64 bits - from config
}

library CompressedProposalLib {
  using SafeCast for uint256;
  using CompressedTimeMath for Timestamp;
  using CompressedTimeMath for CompressedTimestamp;
  using BallotLib for CompressedBallot;

  /**
   * @notice Add yea votes to the proposal
   * @param _compressed Storage pointer to compressed proposal
   * @param _amount The amount of yea votes to add
   */
  function addYea(CompressedProposal storage _compressed, uint256 _amount) internal {
    _compressed.summedBallot = _compressed.summedBallot.addYea(_amount);
  }

  /**
   * @notice Add nay votes to the proposal
   * @param _compressed Storage pointer to compressed proposal
   * @param _amount The amount of nay votes to add
   */
  function addNay(CompressedProposal storage _compressed, uint256 _amount) internal {
    _compressed.summedBallot = _compressed.summedBallot.addNay(_amount);
  }

  /**
   * @notice Get yea and nay votes
   * @param _compressed Storage pointer to compressed proposal
   * @return yea The yea votes
   * @return nay The nay votes
   */
  function getVotes(CompressedProposal storage _compressed) internal view returns (uint256 yea, uint256 nay) {
    yea = _compressed.summedBallot.getYea();
    nay = _compressed.summedBallot.getNay();
  }

  /**
   * @notice Create a compressed proposal from uncompressed data and config
   * @param _proposer The proposal creator
   * @param _payload The payload to execute
   * @param _creation The creation timestamp
   * @param _config The compressed configuration to embed
   * @return The compressed proposal
   */
  function create(address _proposer, IPayload _payload, Timestamp _creation, CompressedConfiguration memory _config)
    internal
    pure
    returns (CompressedProposal memory)
  {
    return CompressedProposal({
      proposer: _proposer,
      minimumVotes: _config.minimumVotes,
      cachedState: ProposalState.Pending,
      creation: _creation.compress(),
      votingDelay: _config.votingDelay,
      votingDuration: _config.votingDuration,
      executionDelay: _config.executionDelay,
      gracePeriod: _config.gracePeriod,
      quorum: _config.quorum,
      summedBallot: CompressedBallot.wrap(0),
      payload: _payload,
      requiredYeaMargin: _config.requiredYeaMargin
    });
  }

  /**
   * @notice Compress an uncompressed Proposal into a CompressedProposal
   * @param _proposal The uncompressed proposal to compress
   * @return The compressed proposal
   */
  function compress(Proposal memory _proposal) internal pure returns (CompressedProposal memory) {
    return CompressedProposal({
      proposer: _proposal.proposer,
      minimumVotes: _proposal.config.minimumVotes.toUint96(),
      cachedState: _proposal.cachedState,
      creation: _proposal.creation.compress(),
      votingDelay: _proposal.config.votingDelay.compress(),
      votingDuration: _proposal.config.votingDuration.compress(),
      executionDelay: _proposal.config.executionDelay.compress(),
      gracePeriod: _proposal.config.gracePeriod.compress(),
      quorum: _proposal.config.quorum.toUint64(),
      summedBallot: BallotLib.compress(_proposal.summedBallot),
      payload: _proposal.payload,
      requiredYeaMargin: _proposal.config.requiredYeaMargin.toUint64()
    });
  }

  /**
   * @notice Decompress a CompressedProposal into a standard Proposal
   * @param _compressed The compressed proposal
   * @return The uncompressed proposal
   */
  function decompress(CompressedProposal memory _compressed) internal pure returns (Proposal memory) {
    return Proposal({
      config: ProposalConfiguration({
        votingDelay: _compressed.votingDelay.decompress(),
        votingDuration: _compressed.votingDuration.decompress(),
        executionDelay: _compressed.executionDelay.decompress(),
        gracePeriod: _compressed.gracePeriod.decompress(),
        quorum: _compressed.quorum,
        requiredYeaMargin: _compressed.requiredYeaMargin,
        minimumVotes: _compressed.minimumVotes
      }),
      cachedState: _compressed.cachedState,
      payload: _compressed.payload,
      proposer: _compressed.proposer,
      creation: _compressed.creation.decompress(),
      summedBallot: _compressed.summedBallot.decompress()
    });
  }
}


// File: lib/l1-contracts/src/governance/libraries/ConfigurationLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {Configuration} from "@aztec/governance/interfaces/IGovernance.sol";
import {CompressedConfiguration} from "@aztec/governance/libraries/compressed-data/Configuration.sol";
import {Errors} from "@aztec/governance/libraries/Errors.sol";
import {CompressedTimeMath, CompressedTimestamp} from "@aztec/shared/libraries/CompressedTimeMath.sol";
import {Timestamp} from "@aztec/shared/libraries/TimeMath.sol";

library ConfigurationLib {
  using CompressedTimeMath for CompressedTimestamp;

  uint256 internal constant QUORUM_LOWER = 1;
  uint256 internal constant QUORUM_UPPER = 1e18;

  uint256 internal constant REQUIRED_YEA_MARGIN_UPPER = 1e18;

  uint256 internal constant VOTES_LOWER = 1;
  uint256 internal constant VOTES_UPPER = type(uint96).max; // Maximum for compressed storage (uint96)

  uint256 internal constant LOCK_AMOUNT_LOWER = 2;
  uint256 internal constant LOCK_AMOUNT_UPPER = type(uint96).max; // Maximum for compressed storage (uint96)

  Timestamp internal constant TIME_LOWER = Timestamp.wrap(60);
  Timestamp internal constant TIME_UPPER = Timestamp.wrap(90 * 24 * 3600);

  /**
   * @notice The delay after which a withdrawal can be finalized.
   * @dev This applies to the "normal" withdrawal, not one induced by proposeWithLock.
   * @dev Making the delay equal to the voting duration + execution delay + a "small buffer"
   * ensures that if you were able to vote on a proposal, someone may execute it before you can exit.
   *
   * The "small buffer" is somewhat arbitrarily set to the votingDelay / 5.
   */
  function getWithdrawalDelay(CompressedConfiguration storage _self) internal view returns (Timestamp) {
    Timestamp votingDelay = _self.votingDelay.decompress();
    Timestamp votingDuration = _self.votingDuration.decompress();
    Timestamp executionDelay = _self.executionDelay.decompress();

    return Timestamp.wrap(Timestamp.unwrap(votingDelay) / 5) + votingDuration + executionDelay;
  }

  /**
   * @notice
   * @dev     We specify `memory` here since it is called on outside import for validation
   *          before writing it to state.
   */
  function assertValid(Configuration memory _self) internal pure {
    require(_self.quorum >= QUORUM_LOWER, Errors.Governance__ConfigurationLib__QuorumTooSmall());
    require(_self.quorum <= QUORUM_UPPER, Errors.Governance__ConfigurationLib__QuorumTooBig());

    require(
      _self.requiredYeaMargin <= REQUIRED_YEA_MARGIN_UPPER,
      Errors.Governance__ConfigurationLib__RequiredYeaMarginTooBig()
    );

    require(_self.minimumVotes >= VOTES_LOWER, Errors.Governance__ConfigurationLib__InvalidMinimumVotes());
    require(_self.minimumVotes <= VOTES_UPPER, Errors.Governance__ConfigurationLib__InvalidMinimumVotes());

    require(
      _self.proposeConfig.lockAmount >= LOCK_AMOUNT_LOWER, Errors.Governance__ConfigurationLib__LockAmountTooSmall()
    );
    require(
      _self.proposeConfig.lockAmount <= LOCK_AMOUNT_UPPER, Errors.Governance__ConfigurationLib__LockAmountTooBig()
    );

    // Beyond checking the bounds like this, it might be useful to ensure that the value is larger than the withdrawal
    // delay. this, can be useful if one want to ensure that the "locker" cannot himself vote in the proposal, but as
    // it is unclear if this is a useful property, it is not enforced.
    require(_self.proposeConfig.lockDelay >= TIME_LOWER, Errors.Governance__ConfigurationLib__TimeTooSmall("LockDelay"));
    require(
      _self.proposeConfig.lockDelay <= Timestamp.wrap(type(uint32).max),
      Errors.Governance__ConfigurationLib__TimeTooBig("LockDelay")
    );

    require(_self.votingDelay >= TIME_LOWER, Errors.Governance__ConfigurationLib__TimeTooSmall("VotingDelay"));
    require(_self.votingDelay <= TIME_UPPER, Errors.Governance__ConfigurationLib__TimeTooBig("VotingDelay"));

    require(_self.votingDuration >= TIME_LOWER, Errors.Governance__ConfigurationLib__TimeTooSmall("VotingDuration"));
    require(_self.votingDuration <= TIME_UPPER, Errors.Governance__ConfigurationLib__TimeTooBig("VotingDuration"));

    require(_self.executionDelay >= TIME_LOWER, Errors.Governance__ConfigurationLib__TimeTooSmall("ExecutionDelay"));
    require(_self.executionDelay <= TIME_UPPER, Errors.Governance__ConfigurationLib__TimeTooBig("ExecutionDelay"));

    require(_self.gracePeriod >= TIME_LOWER, Errors.Governance__ConfigurationLib__TimeTooSmall("GracePeriod"));
    require(_self.gracePeriod <= TIME_UPPER, Errors.Governance__ConfigurationLib__TimeTooBig("GracePeriod"));
  }
}


// File: lib/l1-contracts/src/governance/GSEPayload.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {IGSE} from "@aztec/governance/GSE.sol";
import {IRegistry} from "@aztec/governance/interfaces/IRegistry.sol";
import {Errors} from "@aztec/governance/libraries/Errors.sol";
import {IPayload} from "./interfaces/IPayload.sol";
import {IProposerPayload} from "./interfaces/IProposerPayload.sol";

/**
 * @title   GSEPayload
 *
 * @notice  This contract is used by the GovernanceProposer to enforce checks on an existing payload.
 *
 * In the GovernanceProposer, support for payloads may be signalled by the current block proposer of the
 * current canonical rollup according to the Registry. Once a payload receives enough support,
 * it may be submitted by the GovernanceProposer.
 *
 * Instead of proposing the original payload to Governance, the GovernanceProposer creates a new GSEPayload,
 * referencing the original payload. It is this new GSEPayload which is proposed via Governance.propose.
 * If/when the GSE payload is executed, Governance calls `getActions`, which copies the actions of the original
 * payload, and appends a call to `amIValid` to it.
 *
 * NB `amIValid` will fail if the 2/3 of the total stake is not "following latest", irrespective
 * of what the original proposal does.
 * Note that the GSE is used to perform these checks, hence the name.
 * Note this check is skipped if the canonical rollup does not match the latest to avoid livelock cases.
 *
 * For example, if the original proposal is just to update a configuration parameter, but in the meantime
 * half of the stake has exited the latest rollup in the GSE, `amIValid` will fail.
 *
 * In such an event, your recourse is either:
 * - wait for the latest rollup to have at least 2/3 of the total stake
 * - `GSE.proposeWithLock`, which bypasses the GovernanceProposer
 */
contract GSEPayload is IProposerPayload {
  IPayload public immutable ORIGINAL;
  IGSE public immutable GSE;
  IRegistry public immutable REGISTRY;

  constructor(IPayload _originalPayloadProposal, IGSE _gse, IRegistry _registry) {
    ORIGINAL = _originalPayloadProposal;
    GSE = _gse;
    REGISTRY = _registry;
  }

  function getOriginalPayload() external view override(IProposerPayload) returns (IPayload) {
    return ORIGINAL;
  }

  function getURI() external view override(IPayload) returns (string memory) {
    return ORIGINAL.getURI();
  }

  /**
   * @notice called by the Governance contract when executing the proposal.
   *
   * Note that this contract simply appends a call to `amIValid` to the original actions.
   */
  function getActions() external view override(IPayload) returns (IPayload.Action[] memory) {
    IPayload.Action[] memory originalActions = ORIGINAL.getActions();
    IPayload.Action[] memory actions = new IPayload.Action[](originalActions.length + 1);

    for (uint256 i = 0; i < originalActions.length; i++) {
      actions[i] = originalActions[i];
    }

    actions[originalActions.length] =
      IPayload.Action({target: address(this), data: abi.encodeWithSelector(GSEPayload.amIValid.selector)});

    return actions;
  }

  /**
   * @notice Validates that the proposal maintains governance system integrity by ensuring
   *         sufficient stake remains on the active rollup after execution.
   *
   * The validation passes when EITHER:
   * 1. The latest rollup (plus bonus instance) has >2/3 of total stake, OR
   * 2. A Registry/GSE mismatch is detected (fail-open to prevent governance livelock)
   *
   * @dev Beware that the >2/3 support means that 1/3 of the stake can be used to reject proposals.
   *
   * @dev The "bonus instance" is a special GSE mechanism where attesters automatically
   *      follow the latest rollup without re-depositing. Their stake counts toward
   *      the latest rollup's total for this validation.
   *
   * @dev LIVELOCK PREVENTION: When canonical != latest, we intentionally return true
   *      to bypass validation. This mismatch typically indicates the GovernanceProposer
   *      is still pointing to a stale GSE contract after a rollup upgrade.
   *
   *      Why this creates a livelock:
   *      - The stale GSE tracks an outdated rollup as "latest"
   *      - The Registry correctly identifies the new rollup as canonical
   *      - Economic incentives drive attesters to follow the canonical (where rewards are)
   *      - The stale GSE's "latest" gradually bleeds stake as rational actors exit
   *      - While theoretically possible to maintain >2/3 stake, it becomes increasingly
   *        unlikely as only inattentive or non-reward-seeking attesters remain
   *      - Proposals keep failing validation, creating a probabilistic livelock where
   *        progress is technically possible but economically improbable
   *
   *      By returning true, we provide an escape hatch that allows governance to
   *      continue functioning despite the misconfiguration, enabling corrective
   *      proposals to update the GovernanceProposer's GSE reference.
   *
   * @dev This function executes as the final action of the proposal (see getActions).
   *      It either reverts with an error (proposal invalid) or returns true (proposal valid).
   *      The boolean return value is effectively ceremonial - only the revert matters.
   *
   * @return Always returns true if the proposal is valid; reverts otherwise
   */
  function amIValid() external view override(IProposerPayload) returns (bool) {
    address canonicalRollup = address(REGISTRY.getCanonicalRollup());
    address latestRollup = GSE.getLatestRollup();

    // Bypass validation on mismatch to prevent economically-driven livelock
    // In theory, >2/3 stake could remain on the stale rollup, but economic
    // incentives make this highly unlikely
    if (canonicalRollup != latestRollup) {
      return true;
    }

    // Standard validation: ensure >2/3 of stake remains with the latest rollup
    uint256 totalSupply = GSE.totalSupply();
    address bonusInstance = GSE.getBonusInstanceAddress();
    uint256 effectiveSupplyOfLatestRollup = GSE.supplyOf(latestRollup) + GSE.supplyOf(bonusInstance);

    require(effectiveSupplyOfLatestRollup > totalSupply * 2 / 3, Errors.GovernanceProposer__GSEPayloadInvalid());
    return true;
  }
}


// File: lib/l1-contracts/src/governance/interfaces/IGovernanceProposer.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
// solhint-disable imports-order
pragma solidity >=0.8.27;

import {IEmpire} from "./IEmpire.sol";

interface IGovernanceProposer is IEmpire {
  function getProposalProposer(uint256 _proposalId) external view returns (address);
  function getGovernance() external view returns (address);
}


// File: lib/l1-contracts/src/governance/proposer/EmpireBase.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
// solhint-disable imports-order
pragma solidity >=0.8.27;

import {SignatureLib, Signature} from "@aztec/shared/libraries/SignatureLib.sol";
import {IEmpire, IEmperor} from "@aztec/governance/interfaces/IEmpire.sol";
import {Slot} from "@aztec/shared/libraries/TimeMath.sol";
import {Errors} from "@aztec/governance/libraries/Errors.sol";
import {IPayload} from "@aztec/governance/interfaces/IPayload.sol";
import {EIP712} from "@oz/utils/cryptography/EIP712.sol";
import {CompressedTimeMath, CompressedSlot} from "@aztec/shared/libraries/CompressedTimeMath.sol";

struct RoundAccounting {
  Slot lastSignalSlot;
  IPayload payloadWithMostSignals;
  bool executed;
}

struct CompressedRoundAccounting {
  CompressedSlot lastSignalSlot;
  IPayload payloadWithMostSignals;
  bool executed;
  mapping(IPayload payload => uint256 count) signalCount;
}

/**
 * @title EmpireBase
 * @author Aztec Labs
 * @notice Abstract base contract for a round-based signaling system where designated entities
 *         signal support for payloads before they are submitted elsewhere.
 *         Works with an IEmperor (i.e. a Rollup) contract to determine the entity that may signal for a given slot.
 *
 * @dev PURPOSE:
 * This contract allows validators to signal their support for payloads.
 *
 * There are two primary implementations of this contract:
 * - The GovernanceProposer
 * - The EmpireSlashingProposer
 *
 * The GovernanceProposer is used to signal support for payloads before they are submitted to the main Governance
 * contract,
 * resulting in a two-stage governance process:
 * 1. Signal gathering (GovernanceProposer contract) - validators indicate support
 * 2. Formal governance (Governance contract) - actual voting and execution
 *
 * The EmpireSlashingProposer is used to signal support for payloads before they are submitted to a Rollup instance's
 * Slasher,
 * resulting in a one-stage slashing process:
 * 1. Signal gathering (EmpireSlashingProposer contract) - validators indicate support
 *
 * @dev KEY CONCEPTS:
 * **Payload**: A contract with a list of actions (contract calls) to perform.
 *
 * **Rounds**: Time is divided into rounds of ROUND_SIZE slots. Payloads compete for support
 * within a round.
 *
 * **Instances**: Refers to an instance of the rollup contract, which in this case is exposed via a simplified IEmperor
 * interface.
 * This contract only needs the instance to determine the current slot (to compute the round), and the current block
 * proposer.
 *
 * **Signalers**: Each slot has a designated signaler (determined by IEmperor).
 * Only the current slot's signaler can signal support, either directly or via signature.
 * In the current implementation, the entity that may propose a block (i.e. the "proposer") is the signaler.
 *
 * **Signaling**
 * - One signal per slot (enforced by tracking lastSignalSlot)
 * - Signals accumulate for payloads within a round
 * - First payload to reach QUORUM_SIZE becomes submittable
 *
 * **Submission**
 * - Payloads can be submitted after their round ends with `submitRoundWinner(uint256 _roundNumber)`
 * - Round winner must have received at least QUORUM_SIZE signals
 * - Submission window: LIFETIME_IN_ROUNDS (5 rounds)
 * - Each round's leading payload can only be submitted once
 * - `_handleRoundWinner(IPayload _payload)` on the implementing contract is called to handle the winner
 *
 * @dev SYSTEM PARAMETERS:
 * - QUORUM_SIZE: Minimum signals needed for submission
 * - ROUND_SIZE: Slots per round
 * - Constraint: QUORUM_SIZE > ROUND_SIZE/2 and QUORUM_SIZE ≤ ROUND_SIZE
 * Note that it it possible to have QUORUM_SIZE = 1 for ROUND_SIZE = 1, which effectively give all the
 * power to the first signal.
 *
 * @dev SIGNALING METHODS:
 * 1. Direct signal: Current signaler calls `signal()`
 * 2. Delegated signal: Anyone submits with signaler's signature via `signalWithSig()`
 *    - Uses EIP-712 for signature verification
 *    - Includes slot and instance to prevent replay attacks
 *
 * @dev ABSTRACT FUNCTIONS:
 * Implementing contracts must provide:
 * - `getInstance()`: Returns the IEmperor instance for slot/signaler info
 * - `_handleRoundWinner(IPayload _payload)`: Called during `submitRoundWinner`
 *
 * Note this contract can support multiple instances/rollups. This is because the instance is retrieved dynamically from
 * the
 * underlying implementation. For example, when the GovernanceProposer is used, the instance is the canonical rollup,
 * which will change whenever there is a new canonical rollup.
 *
 * This also means that if the new canonical rollup does not support the IEmperor interface, this contract will not
 * work,
 * and a different implementation will need to be specified as part of the payload which deploys the new canonical
 * instance.
 */
abstract contract EmpireBase is EIP712, IEmpire {
  using SignatureLib for Signature;
  using CompressedTimeMath for Slot;
  using CompressedTimeMath for CompressedSlot;

  // EIP-712 type hash for the Signal struct
  bytes32 public constant SIGNAL_TYPEHASH = keccak256("Signal(address payload,uint256 slot,address instance)");

  // The number of signals needed for a payload to be considered submittable.
  uint256 public immutable QUORUM_SIZE;
  // The number of slots per round.
  uint256 public immutable ROUND_SIZE;
  // The number of rounds that a round winner may be submitted for, after it have passed.
  uint256 public immutable LIFETIME_IN_ROUNDS;
  // The number of rounds that must elapse before a round winner may be submitted.
  uint256 public immutable EXECUTION_DELAY_IN_ROUNDS;

  // Mapping of instance to round number to round accounting.
  mapping(address instance => mapping(uint256 roundNumber => CompressedRoundAccounting)) internal rounds;

  constructor(uint256 _quorumSize, uint256 _roundSize, uint256 _lifetimeInRounds, uint256 _executionDelayInRounds)
    EIP712("EmpireBase", "1")
  {
    QUORUM_SIZE = _quorumSize;
    ROUND_SIZE = _roundSize;
    LIFETIME_IN_ROUNDS = _lifetimeInRounds;
    EXECUTION_DELAY_IN_ROUNDS = _executionDelayInRounds;

    require(QUORUM_SIZE > ROUND_SIZE / 2, Errors.EmpireBase__InvalidQuorumAndRoundSize(QUORUM_SIZE, ROUND_SIZE));
    require(QUORUM_SIZE <= ROUND_SIZE, Errors.EmpireBase__QuorumCannotBeLargerThanRoundSize(QUORUM_SIZE, ROUND_SIZE));

    require(
      LIFETIME_IN_ROUNDS > EXECUTION_DELAY_IN_ROUNDS,
      Errors.EmpireBase__InvalidLifetimeAndExecutionDelay(LIFETIME_IN_ROUNDS, EXECUTION_DELAY_IN_ROUNDS)
    );
  }

  /**
   * @notice	Signal support for a payload
   *
   * @dev this only works if msg.sender is the current signaler
   *
   * @param _payload - The address of the IPayload to signal support for
   *
   * @return True if executed successfully, false otherwise
   */
  function signal(IPayload _payload) external override(IEmpire) returns (bool) {
    return _internalSignal(_payload, Signature({v: 0, r: bytes32(0), s: bytes32(0)}));
  }

  /**
   * @notice	Signal support for a payload with a signature from the current signaler
   *
   * @param _payload - The payload to signal support for
   * @param _sig - A signature from the signaler
   *
   * @return True if executed successfully, false otherwise
   */
  function signalWithSig(IPayload _payload, Signature memory _sig) external override(IEmpire) returns (bool) {
    return _internalSignal(_payload, _sig);
  }

  /**
   * @notice  Submit the round winner to the implementation's `_handleRoundWinner` function
   *
   * @dev calls `_handleRoundWinner` on the implementing contract with the winning payload, if applicable.
   *
   * @param _roundNumber - The round number to execute
   *
   * @return True if executed successfully, false otherwise
   */
  function submitRoundWinner(uint256 _roundNumber) external override(IEmpire) returns (bool) {
    // Need to ensure that the round is not active.
    address instance = getInstance();
    require(instance.code.length > 0, Errors.EmpireBase__InstanceHaveNoCode(instance));

    IEmperor selection = IEmperor(instance);
    Slot currentSlot = selection.getCurrentSlot();

    uint256 currentRound = computeRound(currentSlot);

    require(
      currentRound > _roundNumber + EXECUTION_DELAY_IN_ROUNDS,
      Errors.EmpireBase__RoundTooNew(_roundNumber, currentRound)
    );

    require(
      currentRound <= _roundNumber + LIFETIME_IN_ROUNDS, Errors.EmpireBase__RoundTooOld(_roundNumber, currentRound)
    );

    CompressedRoundAccounting storage round = rounds[instance][_roundNumber];
    require(!round.executed, Errors.EmpireBase__PayloadAlreadySubmitted(_roundNumber));

    // If the payload with the most signals is address(0) there are nothing to execute and it is a no-op.
    // This will be the case if no signals have been cast during a round, or if people have simple signalled
    // for nothing to happen (the same as not signalling).
    require(round.payloadWithMostSignals != IPayload(address(0)), Errors.EmpireBase__PayloadCannotBeAddressZero());
    uint256 signalsCast = round.signalCount[round.payloadWithMostSignals];
    require(signalsCast >= QUORUM_SIZE, Errors.EmpireBase__InsufficientSignals(signalsCast, QUORUM_SIZE));

    round.executed = true;

    emit PayloadSubmitted(round.payloadWithMostSignals, _roundNumber);

    require(
      _handleRoundWinner(round.payloadWithMostSignals),
      Errors.EmpireBase__FailedToSubmitRoundWinner(round.payloadWithMostSignals)
    );
    return true;
  }

  /**
   * @notice  Fetch the signal count for a specific payload in a specific round on a specific instance
   *
   * @param _instance - The address of the instance
   * @param _round - The round to lookup
   * @param _payload - The payload to lookup
   *
   * @return The number of signals
   */
  function signalCount(address _instance, uint256 _round, IPayload _payload)
    external
    view
    override(IEmpire)
    returns (uint256)
  {
    return rounds[_instance][_round].signalCount[_payload];
  }

  /**
   * @notice  Computes the round at the current slot
   *
   * @return The round number
   */
  function getCurrentRound() external view returns (uint256) {
    IEmperor selection = IEmperor(getInstance());
    Slot currentSlot = selection.getCurrentSlot();
    return computeRound(currentSlot);
  }

  function getRoundData(address _instance, uint256 _round) external view returns (RoundAccounting memory) {
    CompressedRoundAccounting storage compressedRound = rounds[_instance][_round];
    return RoundAccounting({
      lastSignalSlot: compressedRound.lastSignalSlot.decompress(),
      payloadWithMostSignals: compressedRound.payloadWithMostSignals,
      executed: compressedRound.executed
    });
  }

  /**
   * @notice Computes the round at the given slot
   *
   * @param _slot - The slot to compute round for
   *
   * @return The round number
   */
  function computeRound(Slot _slot) public view override(IEmpire) returns (uint256) {
    return Slot.unwrap(_slot) / ROUND_SIZE;
  }

  function getSignalSignatureDigest(IPayload _payload, Slot _slot) public view returns (bytes32) {
    return _hashTypedDataV4(keccak256(abi.encode(SIGNAL_TYPEHASH, _payload, _slot, getInstance())));
  }

  // Virtual functions
  function getInstance() public view virtual override(IEmpire) returns (address);
  function _handleRoundWinner(IPayload _payload) internal virtual returns (bool);

  function _internalSignal(IPayload _payload, Signature memory _sig) internal returns (bool) {
    address instance = getInstance();
    require(instance.code.length > 0, Errors.EmpireBase__InstanceHaveNoCode(instance));

    IEmperor selection = IEmperor(instance);
    Slot currentSlot = selection.getCurrentSlot();

    uint256 roundNumber = computeRound(currentSlot);

    CompressedRoundAccounting storage round = rounds[instance][roundNumber];

    // Ensure that time have progressed since the last slot. If not, the current proposer might send multiple signals
    require(currentSlot > round.lastSignalSlot.decompress(), Errors.EmpireBase__SignalAlreadyCastForSlot(currentSlot));
    round.lastSignalSlot = currentSlot.compress();

    address signaler = selection.getCurrentProposer();

    if (_sig.isEmpty()) {
      require(msg.sender == signaler, Errors.EmpireBase__OnlyProposerCanSignal(msg.sender, signaler));
    } else {
      bytes32 digest = getSignalSignatureDigest(_payload, currentSlot);

      // _sig.verify will throw if invalid, it is more my sanity that I am doing this for.
      require(_sig.verify(signaler, digest), Errors.EmpireBase__OnlyProposerCanSignal(msg.sender, signaler));
    }

    round.signalCount[_payload] += 1;

    if (
      round.payloadWithMostSignals != _payload
        && round.signalCount[_payload] > round.signalCount[round.payloadWithMostSignals]
    ) {
      round.payloadWithMostSignals = _payload;
    }

    emit SignalCast(_payload, roundNumber, signaler);

    if (round.signalCount[_payload] == QUORUM_SIZE) {
      emit PayloadSubmittable(_payload, roundNumber);
    }

    return true;
  }
}


// File: lib/openzeppelin-contracts/contracts/interfaces/IERC1363.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (interfaces/IERC1363.sol)

pragma solidity ^0.8.20;

import {IERC20} from "./IERC20.sol";
import {IERC165} from "./IERC165.sol";

/**
 * @title IERC1363
 * @dev Interface of the ERC-1363 standard as defined in the https://eips.ethereum.org/EIPS/eip-1363[ERC-1363].
 *
 * Defines an extension interface for ERC-20 tokens that supports executing code on a recipient contract
 * after `transfer` or `transferFrom`, or code on a spender contract after `approve`, in a single transaction.
 */
interface IERC1363 is IERC20, IERC165 {
    /*
     * Note: the ERC-165 identifier for this interface is 0xb0202a11.
     * 0xb0202a11 ===
     *   bytes4(keccak256('transferAndCall(address,uint256)')) ^
     *   bytes4(keccak256('transferAndCall(address,uint256,bytes)')) ^
     *   bytes4(keccak256('transferFromAndCall(address,address,uint256)')) ^
     *   bytes4(keccak256('transferFromAndCall(address,address,uint256,bytes)')) ^
     *   bytes4(keccak256('approveAndCall(address,uint256)')) ^
     *   bytes4(keccak256('approveAndCall(address,uint256,bytes)'))
     */

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferAndCall(address to, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @param data Additional data with no specified format, sent in call to `to`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the allowance mechanism
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param from The address which you want to send tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferFromAndCall(address from, address to, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the allowance mechanism
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param from The address which you want to send tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @param data Additional data with no specified format, sent in call to `to`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferFromAndCall(address from, address to, uint256 value, bytes calldata data) external returns (bool);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens and then calls {IERC1363Spender-onApprovalReceived} on `spender`.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function approveAndCall(address spender, uint256 value) external returns (bool);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens and then calls {IERC1363Spender-onApprovalReceived} on `spender`.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @param data Additional data with no specified format, sent in call to `spender`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function approveAndCall(address spender, uint256 value, bytes calldata data) external returns (bool);
}


// File: lib/l1-contracts/src/governance/interfaces/IBn254LibWrapper.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {G1Point, G2Point} from "@aztec/shared/libraries/BN254Lib.sol";

interface IBn254LibWrapper {
  function proofOfPossession(
    G1Point memory _publicKeyInG1,
    G2Point memory _publicKeyInG2,
    G1Point memory _proofOfPossession
  ) external view returns (bool);

  function g1ToDigestPoint(G1Point memory pk1) external view returns (G1Point memory);
}


// File: lib/openzeppelin-contracts/contracts/utils/Context.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.1) (utils/Context.sol)

pragma solidity ^0.8.20;

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}


// File: lib/l1-contracts/src/core/libraries/crypto/SampleLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {Errors} from "@aztec/core/libraries/Errors.sol";
import {SlotDerivation} from "@oz/utils/SlotDerivation.sol";
import {TransientSlot} from "@oz/utils/TransientSlot.sol";

/**
 * @title   SampleLib
 * @author  Anaxandridas II
 * @notice  A tiny library to draw committee indices using a sample without replacement algorithm.
 */
library SampleLib {
  using SlotDerivation for string;
  using SlotDerivation for bytes32;
  using TransientSlot for *;

  // Namespace for transient storage keys used within this library
  string private constant OVERRIDE_NAMESPACE = "Aztec.SampleLib.Override";

  /**
   * Compute Committee
   *
   * @param _committeeSize - The size of the committee
   * @param _indexCount - The total number of indices
   * @param _seed - The seed to use for shuffling
   *
   * @dev assumption, _committeeSize <= _indexCount
   *
   * @return indices - The indices of the committee
   */
  function computeCommittee(uint256 _committeeSize, uint256 _indexCount, uint256 _seed)
    internal
    returns (uint256[] memory)
  {
    require(_committeeSize <= _indexCount, Errors.SampleLib__SampleLargerThanIndex(_committeeSize, _indexCount));

    if (_committeeSize == 0) {
      return new uint256[](0);
    }

    uint256[] memory sampledIndices = new uint256[](_committeeSize);

    uint256 upperLimit = _indexCount - 1;

    for (uint256 index = 0; index < _committeeSize; index++) {
      uint256 sampledIndex = computeSampleIndex(index, upperLimit + 1, _seed);

      // Get index, or its swapped override
      sampledIndices[index] = getValue(sampledIndex);
      if (upperLimit > 0) {
        // Swap with the last index
        setOverrideValue(sampledIndex, getValue(upperLimit));
        // Decrement the upper limit
        upperLimit--;
      }
    }

    // Clear transient storage.
    // Note that we are clearing the `sampleIndices` and do not keep track of a separate list of
    // `sampleIndex` values that were written to. The reasoning is that we only overwrite values for
    // duplicate cases, so `sampleIndices` is a superset of the `sampleIndex` values that have been drawn
    // (to account for duplicates). Therefore, clearing `sampleIndices` clears everything.
    // Due to the cost of `tstore` and `tload` operations, it is cheaper to overwrite all values
    // rather than checking if there is anything to override.
    for (uint256 i = 0; i < _committeeSize; i++) {
      setOverrideValue(sampledIndices[i], 0);
    }

    return sampledIndices;
  }

  function setOverrideValue(uint256 _index, uint256 _value) internal {
    OVERRIDE_NAMESPACE.erc7201Slot().deriveMapping(_index).asUint256().tstore(_value);
  }

  function getValue(uint256 _index) internal view returns (uint256) {
    uint256 overrideValue = getOverrideValue(_index);
    if (overrideValue != 0) {
      return overrideValue;
    }

    return _index;
  }

  function getOverrideValue(uint256 _index) internal view returns (uint256) {
    return OVERRIDE_NAMESPACE.erc7201Slot().deriveMapping(_index).asUint256().tload();
  }

  /**
   * @notice  Compute the sample index for a given index, seed and index count.
   *
   * @param _index - The index to shuffle
   * @param _indexCount - The total number of indices
   * @param _seed - The seed to use for shuffling
   *
   * @return shuffledIndex - The shuffled index
   */
  function computeSampleIndex(uint256 _index, uint256 _indexCount, uint256 _seed) internal pure returns (uint256) {
    // Cannot modulo by 0 and if 1, then only acceptable value is 0
    if (_indexCount <= 1) {
      return 0;
    }

    return uint256(keccak256(abi.encodePacked(_seed, _index))) % _indexCount;
  }
}


// File: lib/openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.3.0) (utils/cryptography/MessageHashUtils.sol)

pragma solidity ^0.8.20;

import {Strings} from "../Strings.sol";

/**
 * @dev Signature message hash utilities for producing digests to be consumed by {ECDSA} recovery or signing.
 *
 * The library provides methods for generating a hash of a message that conforms to the
 * https://eips.ethereum.org/EIPS/eip-191[ERC-191] and https://eips.ethereum.org/EIPS/eip-712[EIP 712]
 * specifications.
 */
library MessageHashUtils {
    /**
     * @dev Returns the keccak256 digest of an ERC-191 signed data with version
     * `0x45` (`personal_sign` messages).
     *
     * The digest is calculated by prefixing a bytes32 `messageHash` with
     * `"\x19Ethereum Signed Message:\n32"` and hashing the result. It corresponds with the
     * hash signed when using the https://ethereum.org/en/developers/docs/apis/json-rpc/#eth_sign[`eth_sign`] JSON-RPC method.
     *
     * NOTE: The `messageHash` parameter is intended to be the result of hashing a raw message with
     * keccak256, although any bytes32 value can be safely used because the final digest will
     * be re-hashed.
     *
     * See {ECDSA-recover}.
     */
    function toEthSignedMessageHash(bytes32 messageHash) internal pure returns (bytes32 digest) {
        assembly ("memory-safe") {
            mstore(0x00, "\x19Ethereum Signed Message:\n32") // 32 is the bytes-length of messageHash
            mstore(0x1c, messageHash) // 0x1c (28) is the length of the prefix
            digest := keccak256(0x00, 0x3c) // 0x3c is the length of the prefix (0x1c) + messageHash (0x20)
        }
    }

    /**
     * @dev Returns the keccak256 digest of an ERC-191 signed data with version
     * `0x45` (`personal_sign` messages).
     *
     * The digest is calculated by prefixing an arbitrary `message` with
     * `"\x19Ethereum Signed Message:\n" + len(message)` and hashing the result. It corresponds with the
     * hash signed when using the https://ethereum.org/en/developers/docs/apis/json-rpc/#eth_sign[`eth_sign`] JSON-RPC method.
     *
     * See {ECDSA-recover}.
     */
    function toEthSignedMessageHash(bytes memory message) internal pure returns (bytes32) {
        return
            keccak256(bytes.concat("\x19Ethereum Signed Message:\n", bytes(Strings.toString(message.length)), message));
    }

    /**
     * @dev Returns the keccak256 digest of an ERC-191 signed data with version
     * `0x00` (data with intended validator).
     *
     * The digest is calculated by prefixing an arbitrary `data` with `"\x19\x00"` and the intended
     * `validator` address. Then hashing the result.
     *
     * See {ECDSA-recover}.
     */
    function toDataWithIntendedValidatorHash(address validator, bytes memory data) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"19_00", validator, data));
    }

    /**
     * @dev Variant of {toDataWithIntendedValidatorHash-address-bytes} optimized for cases where `data` is a bytes32.
     */
    function toDataWithIntendedValidatorHash(
        address validator,
        bytes32 messageHash
    ) internal pure returns (bytes32 digest) {
        assembly ("memory-safe") {
            mstore(0x00, hex"19_00")
            mstore(0x02, shl(96, validator))
            mstore(0x16, messageHash)
            digest := keccak256(0x00, 0x36)
        }
    }

    /**
     * @dev Returns the keccak256 digest of an EIP-712 typed data (ERC-191 version `0x01`).
     *
     * The digest is calculated from a `domainSeparator` and a `structHash`, by prefixing them with
     * `\x19\x01` and hashing the result. It corresponds to the hash signed by the
     * https://eips.ethereum.org/EIPS/eip-712[`eth_signTypedData`] JSON-RPC method as part of EIP-712.
     *
     * See {ECDSA-recover}.
     */
    function toTypedDataHash(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32 digest) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, hex"19_01")
            mstore(add(ptr, 0x02), domainSeparator)
            mstore(add(ptr, 0x22), structHash)
            digest := keccak256(ptr, 0x42)
        }
    }
}


// File: lib/openzeppelin-contracts/contracts/utils/SlotDerivation.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.3.0) (utils/SlotDerivation.sol)
// This file was procedurally generated from scripts/generate/templates/SlotDerivation.js.

pragma solidity ^0.8.20;

/**
 * @dev Library for computing storage (and transient storage) locations from namespaces and deriving slots
 * corresponding to standard patterns. The derivation method for array and mapping matches the storage layout used by
 * the solidity language / compiler.
 *
 * See https://docs.soliditylang.org/en/v0.8.20/internals/layout_in_storage.html#mappings-and-dynamic-arrays[Solidity docs for mappings and dynamic arrays.].
 *
 * Example usage:
 * ```solidity
 * contract Example {
 *     // Add the library methods
 *     using StorageSlot for bytes32;
 *     using SlotDerivation for bytes32;
 *
 *     // Declare a namespace
 *     string private constant _NAMESPACE = "<namespace>"; // eg. OpenZeppelin.Slot
 *
 *     function setValueInNamespace(uint256 key, address newValue) internal {
 *         _NAMESPACE.erc7201Slot().deriveMapping(key).getAddressSlot().value = newValue;
 *     }
 *
 *     function getValueInNamespace(uint256 key) internal view returns (address) {
 *         return _NAMESPACE.erc7201Slot().deriveMapping(key).getAddressSlot().value;
 *     }
 * }
 * ```
 *
 * TIP: Consider using this library along with {StorageSlot}.
 *
 * NOTE: This library provides a way to manipulate storage locations in a non-standard way. Tooling for checking
 * upgrade safety will ignore the slots accessed through this library.
 *
 * _Available since v5.1._
 */
library SlotDerivation {
    /**
     * @dev Derive an ERC-7201 slot from a string (namespace).
     */
    function erc7201Slot(string memory namespace) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            mstore(0x00, sub(keccak256(add(namespace, 0x20), mload(namespace)), 1))
            slot := and(keccak256(0x00, 0x20), not(0xff))
        }
    }

    /**
     * @dev Add an offset to a slot to get the n-th element of a structure or an array.
     */
    function offset(bytes32 slot, uint256 pos) internal pure returns (bytes32 result) {
        unchecked {
            return bytes32(uint256(slot) + pos);
        }
    }

    /**
     * @dev Derive the location of the first element in an array from the slot where the length is stored.
     */
    function deriveArray(bytes32 slot) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0x00, slot)
            result := keccak256(0x00, 0x20)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, address key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0x00, and(key, shr(96, not(0))))
            mstore(0x20, slot)
            result := keccak256(0x00, 0x40)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, bool key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0x00, iszero(iszero(key)))
            mstore(0x20, slot)
            result := keccak256(0x00, 0x40)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, bytes32 key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0x00, key)
            mstore(0x20, slot)
            result := keccak256(0x00, 0x40)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, uint256 key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0x00, key)
            mstore(0x20, slot)
            result := keccak256(0x00, 0x40)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, int256 key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0x00, key)
            mstore(0x20, slot)
            result := keccak256(0x00, 0x40)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, string memory key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            let length := mload(key)
            let begin := add(key, 0x20)
            let end := add(begin, length)
            let cache := mload(end)
            mstore(end, slot)
            result := keccak256(begin, add(length, 0x20))
            mstore(end, cache)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, bytes memory key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            let length := mload(key)
            let begin := add(key, 0x20)
            let end := add(begin, length)
            let cache := mload(end)
            mstore(end, slot)
            result := keccak256(begin, add(length, 0x20))
            mstore(end, cache)
        }
    }
}


// File: lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.3.0) (utils/structs/EnumerableSet.sol)
// This file was procedurally generated from scripts/generate/templates/EnumerableSet.js.

pragma solidity ^0.8.20;

import {Arrays} from "../Arrays.sol";

/**
 * @dev Library for managing
 * https://en.wikipedia.org/wiki/Set_(abstract_data_type)[sets] of primitive
 * types.
 *
 * Sets have the following properties:
 *
 * - Elements are added, removed, and checked for existence in constant time
 * (O(1)).
 * - Elements are enumerated in O(n). No guarantees are made on the ordering.
 * - Set can be cleared (all elements removed) in O(n).
 *
 * ```solidity
 * contract Example {
 *     // Add the library methods
 *     using EnumerableSet for EnumerableSet.AddressSet;
 *
 *     // Declare a set state variable
 *     EnumerableSet.AddressSet private mySet;
 * }
 * ```
 *
 * As of v3.3.0, sets of type `bytes32` (`Bytes32Set`), `address` (`AddressSet`)
 * and `uint256` (`UintSet`) are supported.
 *
 * [WARNING]
 * ====
 * Trying to delete such a structure from storage will likely result in data corruption, rendering the structure
 * unusable.
 * See https://github.com/ethereum/solidity/pull/11843[ethereum/solidity#11843] for more info.
 *
 * In order to clean an EnumerableSet, you can either remove all elements one by one or create a fresh instance using an
 * array of EnumerableSet.
 * ====
 */
library EnumerableSet {
    // To implement this library for multiple types with as little code
    // repetition as possible, we write it in terms of a generic Set type with
    // bytes32 values.
    // The Set implementation uses private functions, and user-facing
    // implementations (such as AddressSet) are just wrappers around the
    // underlying Set.
    // This means that we can only create new EnumerableSets for types that fit
    // in bytes32.

    struct Set {
        // Storage of set values
        bytes32[] _values;
        // Position is the index of the value in the `values` array plus 1.
        // Position 0 is used to mean a value is not in the set.
        mapping(bytes32 value => uint256) _positions;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function _add(Set storage set, bytes32 value) private returns (bool) {
        if (!_contains(set, value)) {
            set._values.push(value);
            // The value is stored at length-1, but we add 1 to all indexes
            // and use 0 as a sentinel value
            set._positions[value] = set._values.length;
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function _remove(Set storage set, bytes32 value) private returns (bool) {
        // We cache the value's position to prevent multiple reads from the same storage slot
        uint256 position = set._positions[value];

        if (position != 0) {
            // Equivalent to contains(set, value)
            // To delete an element from the _values array in O(1), we swap the element to delete with the last one in
            // the array, and then remove the last element (sometimes called as 'swap and pop').
            // This modifies the order of the array, as noted in {at}.

            uint256 valueIndex = position - 1;
            uint256 lastIndex = set._values.length - 1;

            if (valueIndex != lastIndex) {
                bytes32 lastValue = set._values[lastIndex];

                // Move the lastValue to the index where the value to delete is
                set._values[valueIndex] = lastValue;
                // Update the tracked position of the lastValue (that was just moved)
                set._positions[lastValue] = position;
            }

            // Delete the slot where the moved value was stored
            set._values.pop();

            // Delete the tracked position for the deleted slot
            delete set._positions[value];

            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Removes all the values from a set. O(n).
     *
     * WARNING: Developers should keep in mind that this function has an unbounded cost and using it may render the
     * function uncallable if the set grows to the point where clearing it consumes too much gas to fit in a block.
     */
    function _clear(Set storage set) private {
        uint256 len = _length(set);
        for (uint256 i = 0; i < len; ++i) {
            delete set._positions[set._values[i]];
        }
        Arrays.unsafeSetLength(set._values, 0);
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function _contains(Set storage set, bytes32 value) private view returns (bool) {
        return set._positions[value] != 0;
    }

    /**
     * @dev Returns the number of values on the set. O(1).
     */
    function _length(Set storage set) private view returns (uint256) {
        return set._values.length;
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function _at(Set storage set, uint256 index) private view returns (bytes32) {
        return set._values[index];
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function _values(Set storage set) private view returns (bytes32[] memory) {
        return set._values;
    }

    // Bytes32Set

    struct Bytes32Set {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(Bytes32Set storage set, bytes32 value) internal returns (bool) {
        return _add(set._inner, value);
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(Bytes32Set storage set, bytes32 value) internal returns (bool) {
        return _remove(set._inner, value);
    }

    /**
     * @dev Removes all the values from a set. O(n).
     *
     * WARNING: Developers should keep in mind that this function has an unbounded cost and using it may render the
     * function uncallable if the set grows to the point where clearing it consumes too much gas to fit in a block.
     */
    function clear(Bytes32Set storage set) internal {
        _clear(set._inner);
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(Bytes32Set storage set, bytes32 value) internal view returns (bool) {
        return _contains(set._inner, value);
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(Bytes32Set storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(Bytes32Set storage set, uint256 index) internal view returns (bytes32) {
        return _at(set._inner, index);
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(Bytes32Set storage set) internal view returns (bytes32[] memory) {
        bytes32[] memory store = _values(set._inner);
        bytes32[] memory result;

        assembly ("memory-safe") {
            result := store
        }

        return result;
    }

    // AddressSet

    struct AddressSet {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(AddressSet storage set, address value) internal returns (bool) {
        return _add(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(AddressSet storage set, address value) internal returns (bool) {
        return _remove(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Removes all the values from a set. O(n).
     *
     * WARNING: Developers should keep in mind that this function has an unbounded cost and using it may render the
     * function uncallable if the set grows to the point where clearing it consumes too much gas to fit in a block.
     */
    function clear(AddressSet storage set) internal {
        _clear(set._inner);
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(AddressSet storage set, address value) internal view returns (bool) {
        return _contains(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(AddressSet storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(AddressSet storage set, uint256 index) internal view returns (address) {
        return address(uint160(uint256(_at(set._inner, index))));
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(AddressSet storage set) internal view returns (address[] memory) {
        bytes32[] memory store = _values(set._inner);
        address[] memory result;

        assembly ("memory-safe") {
            result := store
        }

        return result;
    }

    // UintSet

    struct UintSet {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(UintSet storage set, uint256 value) internal returns (bool) {
        return _add(set._inner, bytes32(value));
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(UintSet storage set, uint256 value) internal returns (bool) {
        return _remove(set._inner, bytes32(value));
    }

    /**
     * @dev Removes all the values from a set. O(n).
     *
     * WARNING: Developers should keep in mind that this function has an unbounded cost and using it may render the
     * function uncallable if the set grows to the point where clearing it consumes too much gas to fit in a block.
     */
    function clear(UintSet storage set) internal {
        _clear(set._inner);
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(UintSet storage set, uint256 value) internal view returns (bool) {
        return _contains(set._inner, bytes32(value));
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(UintSet storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(UintSet storage set, uint256 index) internal view returns (uint256) {
        return uint256(_at(set._inner, index));
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(UintSet storage set) internal view returns (uint256[] memory) {
        bytes32[] memory store = _values(set._inner);
        uint256[] memory result;

        assembly ("memory-safe") {
            result := store
        }

        return result;
    }
}


// File: lib/openzeppelin-contracts/contracts/utils/TransientSlot.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.3.0) (utils/TransientSlot.sol)
// This file was procedurally generated from scripts/generate/templates/TransientSlot.js.

pragma solidity ^0.8.24;

/**
 * @dev Library for reading and writing value-types to specific transient storage slots.
 *
 * Transient slots are often used to store temporary values that are removed after the current transaction.
 * This library helps with reading and writing to such slots without the need for inline assembly.
 *
 *  * Example reading and writing values using transient storage:
 * ```solidity
 * contract Lock {
 *     using TransientSlot for *;
 *
 *     // Define the slot. Alternatively, use the SlotDerivation library to derive the slot.
 *     bytes32 internal constant _LOCK_SLOT = 0xf4678858b2b588224636b8522b729e7722d32fc491da849ed75b3fdf3c84f542;
 *
 *     modifier locked() {
 *         require(!_LOCK_SLOT.asBoolean().tload());
 *
 *         _LOCK_SLOT.asBoolean().tstore(true);
 *         _;
 *         _LOCK_SLOT.asBoolean().tstore(false);
 *     }
 * }
 * ```
 *
 * TIP: Consider using this library along with {SlotDerivation}.
 */
library TransientSlot {
    /**
     * @dev UDVT that represents a slot holding an address.
     */
    type AddressSlot is bytes32;

    /**
     * @dev Cast an arbitrary slot to a AddressSlot.
     */
    function asAddress(bytes32 slot) internal pure returns (AddressSlot) {
        return AddressSlot.wrap(slot);
    }

    /**
     * @dev UDVT that represents a slot holding a bool.
     */
    type BooleanSlot is bytes32;

    /**
     * @dev Cast an arbitrary slot to a BooleanSlot.
     */
    function asBoolean(bytes32 slot) internal pure returns (BooleanSlot) {
        return BooleanSlot.wrap(slot);
    }

    /**
     * @dev UDVT that represents a slot holding a bytes32.
     */
    type Bytes32Slot is bytes32;

    /**
     * @dev Cast an arbitrary slot to a Bytes32Slot.
     */
    function asBytes32(bytes32 slot) internal pure returns (Bytes32Slot) {
        return Bytes32Slot.wrap(slot);
    }

    /**
     * @dev UDVT that represents a slot holding a uint256.
     */
    type Uint256Slot is bytes32;

    /**
     * @dev Cast an arbitrary slot to a Uint256Slot.
     */
    function asUint256(bytes32 slot) internal pure returns (Uint256Slot) {
        return Uint256Slot.wrap(slot);
    }

    /**
     * @dev UDVT that represents a slot holding a int256.
     */
    type Int256Slot is bytes32;

    /**
     * @dev Cast an arbitrary slot to a Int256Slot.
     */
    function asInt256(bytes32 slot) internal pure returns (Int256Slot) {
        return Int256Slot.wrap(slot);
    }

    /**
     * @dev Load the value held at location `slot` in transient storage.
     */
    function tload(AddressSlot slot) internal view returns (address value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    /**
     * @dev Store `value` at location `slot` in transient storage.
     */
    function tstore(AddressSlot slot, address value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    /**
     * @dev Load the value held at location `slot` in transient storage.
     */
    function tload(BooleanSlot slot) internal view returns (bool value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    /**
     * @dev Store `value` at location `slot` in transient storage.
     */
    function tstore(BooleanSlot slot, bool value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    /**
     * @dev Load the value held at location `slot` in transient storage.
     */
    function tload(Bytes32Slot slot) internal view returns (bytes32 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    /**
     * @dev Store `value` at location `slot` in transient storage.
     */
    function tstore(Bytes32Slot slot, bytes32 value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    /**
     * @dev Load the value held at location `slot` in transient storage.
     */
    function tload(Uint256Slot slot) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    /**
     * @dev Store `value` at location `slot` in transient storage.
     */
    function tstore(Uint256Slot slot, uint256 value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    /**
     * @dev Load the value held at location `slot` in transient storage.
     */
    function tload(Int256Slot slot) internal view returns (int256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    /**
     * @dev Store `value` at location `slot` in transient storage.
     */
    function tstore(Int256Slot slot, int256 value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }
}


// File: lib/l1-contracts/src/core/libraries/rollup/EpochProofLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {BlobLib} from "@aztec-blob-lib/BlobLib.sol";
import {SubmitEpochRootProofArgs, PublicInputArgs, IRollupCore, RollupStore} from "@aztec/core/interfaces/IRollup.sol";
import {CompressedTempBlockLog} from "@aztec/core/libraries/compressed-data/BlockLog.sol";
import {CompressedFeeHeader, FeeHeaderLib} from "@aztec/core/libraries/compressed-data/fees/FeeStructs.sol";
import {ChainTipsLib, CompressedChainTips} from "@aztec/core/libraries/compressed-data/Tips.sol";
import {Constants} from "@aztec/core/libraries/ConstantsGen.sol";
import {Errors} from "@aztec/core/libraries/Errors.sol";
import {AttestationLib, CommitteeAttestations} from "@aztec/core/libraries/rollup/AttestationLib.sol";
import {RewardLib} from "@aztec/core/libraries/rollup/RewardLib.sol";
import {STFLib} from "@aztec/core/libraries/rollup/STFLib.sol";
import {ValidatorSelectionLib} from "@aztec/core/libraries/rollup/ValidatorSelectionLib.sol";
import {Timestamp, Slot, Epoch, TimeLib} from "@aztec/core/libraries/TimeLib.sol";
import {CompressedSlot, CompressedTimeMath} from "@aztec/shared/libraries/CompressedTimeMath.sol";
import {Math} from "@oz/utils/math/Math.sol";
import {SafeCast} from "@oz/utils/math/SafeCast.sol";

/**
 * @title EpochProofLib
 * @author Aztec Labs
 * @notice Core library responsible for epoch proof submission and verification in the Aztec rollup.
 *
 * @dev This library implements epoch proof verification, which advances the proven chain tip.
 *      - Epoch boundary validation and proof deadline enforcement
 *      - Attestation verification for the last block in the proven range (which may be a partial epoch)
 *      - Validity proof verification using the configured verifier
 *      - Blob commitment validation and batched blob proof verification
 *      - Public input assembly and validation for the root rollup circuit
 *      - Proven chain tip advancement and reward distribution
 *
 *      Integration with RollupCore:
 *      The submitEpochRootProof() function is the main entry point called from RollupCore.submitEpochRootProof().
 *      It serves as the mechanism by which provers can finalize epochs, advancing the proven chain tip and
 *      triggering reward distribution. This is a critical operation that moves blocks from "pending" to "proven"
 *      status.
 *
 *      Attestation Verification:
 *      Before accepting an epoch proof, this library verifies the attestations for the end block of the proof.
 *      This ensures that the committee has properly validated the final state of the proof. Note that this is
 *      equivalent to verifying the attestations for every prior block, since the committee should not attest
 *      to a block unless its ancestors are also valid and have been attested to. This step checks that the committee
 *      have agreed on the same output state of the proven range. For honest nodes, this is done by re-executing the
 *      transactions in the proven range and matching the state root, effectively acting as training wheels for the
 *      proving of public executions (i.e., the AVM).
 *
 *      Proof Submission Window:
 *      Epochs have a configurable proof submission deadline measured in epochs after the epoch's completion.
 *      This prevents indefinite delays in proof submission while allowing reasonable time for proof generation.
 *      If no proof is submitted within the deadline, blocks are pruned to maintain chain liveness.
 *
 *      Blob Integration:
 *      The library validates batched blob proofs using EIP-4844's point evaluation precompile and ensures
 *      blob commitments match the claimed rollup data. This provides data availability guarantees while
 *      leveraging Ethereum's native blob storage for cost efficiency.
 */
library EpochProofLib {
  using TimeLib for Slot;
  using TimeLib for Epoch;
  using TimeLib for Timestamp;
  using FeeHeaderLib for CompressedFeeHeader;
  using SafeCast for uint256;
  using ChainTipsLib for CompressedChainTips;
  using AttestationLib for CommitteeAttestations;
  using CompressedTimeMath for CompressedSlot;

  /**
   * @notice Submit a validity proof for an epoch's state transitions, advancing the proven chain tip
   *
   * @dev This is the main entry point for epoch finalization. It performs comprehensive validation
   *      of the epoch proof including attestation verification, archive root validation, blob proof
   *      verification, and validity proof verification. Upon success, advances the proven chain tip and
   *      distributes rewards to the prover and validators.
   *
   *      The function will automatically prune unproven blocks if the pruning window has expired.
   *
   * @dev Events Emitted:
   *      - L2ProofVerified: When proof verification succeeds and proven tip advances
   *
   * @dev Errors Thrown:
   *      - Rollup__InvalidProof: validity proof verification failed
   *      - Rollup__InvalidPreviousArchive: Previous archive root mismatch
   *      - Rollup__InvalidArchive: End archive root mismatch
   *      - Rollup__InvalidAttestations: Attestation verification failed for last block
   *      - Rollup__StartAndEndNotSameEpoch: Proof spans multiple epochs
   *      - Rollup__PastDeadline: Proof submitted after deadline
   *      - Rollup__InvalidFirstEpochProof: Invalid first epoch proof structure
   *      - Rollup__StartIsNotFirstBlockOfEpoch: Start block is not epoch boundary
   *      - Rollup__StartIsNotBuildingOnProven: Start block doesn't build on proven chain
   *      - Rollup__TooManyBlocksInEpoch: Epoch exceeds maximum block count
   *      - Rollup__InvalidBlobProof: Batched blob proof verification failed
   *
   * @param _args The epoch proof submission arguments containing:
   *              - start: First block number in the epoch (inclusive)
   *              - end: Last block number in the epoch (inclusive)
   *              - args: Public inputs (previousArchive, endArchive, endTimestamp, proverId)
   *              - fees: Fee distribution array (recipient-value pairs)
   *              - attestations: Committee attestations for the last block in the epoch
   *              - blobInputs: Batched blob data for EIP-4844 point evaluation precompile
   *              - proof: The validity proof bytes for the root rollup circuit
   */
  function submitEpochRootProof(SubmitEpochRootProofArgs calldata _args) internal {
    if (STFLib.canPruneAtTime(Timestamp.wrap(block.timestamp))) {
      STFLib.prune();
    }

    Epoch endEpoch = assertAcceptable(_args.start, _args.end);

    // Verify attestations for the last block in the epoch
    // -> This serves as training wheels for the public part of the system (proving systems used in public and AVM)
    // ensuring committee agreement on the epoch's validity alongside the cryptographic proof verification below.
    verifyLastBlockAttestations(_args.end, _args.attestations);

    require(verifyEpochRootProof(_args), Errors.Rollup__InvalidProof());

    RollupStore storage rollupStore = STFLib.getStorage();
    rollupStore.tips =
      rollupStore.tips.updateProvenBlockNumber(Math.max(rollupStore.tips.getProvenBlockNumber(), _args.end));

    RewardLib.handleRewardsAndFees(_args, endEpoch);

    emit IRollupCore.L2ProofVerified(_args.end, _args.args.proverId);
  }

  /**
   * @notice Returns the computed public inputs for the given epoch proof.
   *
   * @dev Useful for debugging and testing. Allows submitter to compare their
   * own public inputs used for generating the proof vs the ones assembled
   * by this contract when verifying it.
   *
   * @param  _start - The start of the epoch (inclusive)
   * @param  _end - The end of the epoch (inclusive)
   * @param  _args - Array of public inputs to the proof (previousArchive, endArchive, endTimestamp, outHash, proverId)
   * @param  _fees - Array of recipient-value pairs with fees to be distributed for the epoch
   * @param _blobPublicInputs- The blob public inputs for the proof
   */
  function getEpochProofPublicInputs(
    uint256 _start,
    uint256 _end,
    PublicInputArgs calldata _args,
    bytes32[] calldata _fees,
    bytes calldata _blobPublicInputs
  ) internal view returns (bytes32[] memory) {
    RollupStore storage rollupStore = STFLib.getStorage();

    {
      // We do it this way to provide better error messages than passing along the storage values
      {
        bytes32 expectedPreviousArchive = rollupStore.archives[_start - 1];
        require(
          expectedPreviousArchive == _args.previousArchive,
          Errors.Rollup__InvalidPreviousArchive(expectedPreviousArchive, _args.previousArchive)
        );
      }

      {
        bytes32 expectedEndArchive = rollupStore.archives[_end];
        require(
          expectedEndArchive == _args.endArchive, Errors.Rollup__InvalidArchive(expectedEndArchive, _args.endArchive)
        );
      }
    }

    bytes32[] memory publicInputs = new bytes32[](Constants.ROOT_ROLLUP_PUBLIC_INPUTS_LENGTH);

    // Structure of the root rollup public inputs we need to reassemble:
    //
    // struct RootRollupPublicInputs {
    //   previous_archive_root: Field,
    //   end_archive_root: Field,
    //   proposedBlockHeaderHashes: [Field; Constants.AZTEC_MAX_EPOCH_DURATION],
    //   fees: [FeeRecipient; Constants.AZTEC_MAX_EPOCH_DURATION],
    //   chain_id: Field,
    //   version: Field,
    //   vk_tree_root: Field,
    //   protocol_contract_tree_root: Field,
    //   prover_id: Field,
    //   blob_public_inputs: FinalBlobAccumulatorPublicInputs,
    // }
    {
      // previous_archive.root: the previous archive tree root
      publicInputs[0] = _args.previousArchive;

      // end_archive.root: the new archive tree root
      publicInputs[1] = _args.endArchive;
    }

    uint256 numBlocks = _end - _start + 1;

    for (uint256 i = 0; i < numBlocks; i++) {
      publicInputs[2 + i] = STFLib.getHeaderHash(_start + i);
    }

    uint256 offset = 2 + Constants.AZTEC_MAX_EPOCH_DURATION;

    uint256 feesLength = Constants.AZTEC_MAX_EPOCH_DURATION * 2;
    // fees[2n to 2n + 1]: a fee element, which contains of a recipient and a value
    for (uint256 i = 0; i < feesLength; i++) {
      publicInputs[offset + i] = _fees[i];
    }
    offset += feesLength;

    publicInputs[offset] = bytes32(block.chainid);
    offset += 1;

    publicInputs[offset] = bytes32(uint256(rollupStore.config.version));
    offset += 1;

    // vk_tree_root
    publicInputs[offset] = rollupStore.config.vkTreeRoot;
    offset += 1;

    // protocol_contract_tree_root
    publicInputs[offset] = rollupStore.config.protocolContractTreeRoot;
    offset += 1;

    // prover_id: id of current epoch's prover
    publicInputs[offset] = addressToField(_args.proverId);
    offset += 1;

    // FinalBlobAccumulatorPublicInputs:
    // The blob public inputs do not require the versioned hash of the batched commitment, which is stored in
    // _blobPublicInputs[0:32]
    // or the KZG opening 'proof' (commitment Q) stored in _blobPublicInputs[144:]. They are used in
    // validateBatchedBlob().
    // See BlobLib.sol -> validateBatchedBlob() and calculateBlobCommitmentsHash() for documentation on the below blob
    // related inputs.

    // blobCommitmentsHash
    publicInputs[offset] = STFLib.getBlobCommitmentsHash(_end);
    offset += 1;

    // z
    publicInputs[offset] = bytes32(_blobPublicInputs[32:64]);
    offset += 1;

    // y
    (publicInputs[offset], publicInputs[offset + 1], publicInputs[offset + 2]) =
      bytes32ToBigNum(bytes32(_blobPublicInputs[64:96]));
    offset += 3;

    // To fit into 2 fields, the commitment is split into 31 and 17 byte numbers
    // See yarn-project/foundation/src/blob/index.ts -> commitmentToFields()
    // TODO: The below left pads, possibly inefficiently
    // c[0]
    publicInputs[offset] = bytes32(uint256(uint248(bytes31((_blobPublicInputs[96:127])))));
    // c[1]
    publicInputs[offset + 1] = bytes32(uint256(uint136(bytes17((_blobPublicInputs[127:144])))));
    offset += 2;

    return publicInputs;
  }

  /**
   * @notice Verifies committee attestations for the last block in the epoch before accepting the epoch proof
   *
   * @dev This verification ensures that the committee has properly validated the final state of the epoch
   *      before the proof can be accepted. The function validates that:
   *      1. The provided attestations match the stored attestation hash for the block
   *      2. The attestations have valid signatures from committee members
   *      3. The attestations meet the required threshold (2/3+ of committee)
   *
   * @dev Errors Thrown:
   *      - Rollup__InvalidAttestations: Provided attestations don't match stored hash or fail validation
   *
   * @param _endBlockNumber The last block number in the epoch to verify attestations for
   * @param _attestations The committee attestations containing signatures and validator information
   */
  function verifyLastBlockAttestations(uint256 _endBlockNumber, CommitteeAttestations memory _attestations) private {
    // Get the stored attestation hash and payload digest for the last block
    CompressedTempBlockLog storage blockLog = STFLib.getStorageTempBlockLog(_endBlockNumber);

    // Verify that the provided attestations match the stored hash
    bytes32 providedAttestationsHash = keccak256(abi.encode(_attestations));
    require(providedAttestationsHash == blockLog.attestationsHash, Errors.Rollup__InvalidAttestations());

    // Get the slot and epoch for the last block
    Slot slot = blockLog.slotNumber.decompress();
    Epoch epoch = STFLib.getEpochForBlock(_endBlockNumber);

    ValidatorSelectionLib.verifyAttestations(slot, epoch, _attestations, blockLog.payloadDigest);
  }

  /**
   * @notice Validates that an epoch proof submission meets all acceptance criteria
   *
   * @dev Performs comprehensive validation of epoch boundaries, timing constraints, and chain state:
   *      - Ensures start and end blocks are in the same epoch
   *      - Verifies proof is submitted within the deadline window
   *      - Confirms start block is the first block of its epoch
   *      - Validates start block builds on the proven chain
   *      - Checks epoch doesn't exceed maximum block count
   *
   * @dev Errors Thrown:
   *      - Rollup__StartAndEndNotSameEpoch: Start and end blocks in different epochs
   *      - Rollup__PastDeadline: Proof submitted after deadline
   *      - Rollup__InvalidFirstEpochProof: Invalid structure for first epoch proof
   *      - Rollup__StartIsNotFirstBlockOfEpoch: Start block is not at epoch boundary
   *      - Rollup__StartIsNotBuildingOnProven: Start block doesn't build on proven chain
   *      - Rollup__TooManyBlocksInEpoch: Epoch exceeds maximum allowed blocks
   *
   * @param _start The first block number in the epoch (inclusive)
   * @param _end The last block number in the epoch (inclusive)
   * @return The epoch number that the proof covers
   */
  function assertAcceptable(uint256 _start, uint256 _end) private view returns (Epoch) {
    RollupStore storage rollupStore = STFLib.getStorage();

    Epoch startEpoch = STFLib.getEpochForBlock(_start);
    // This also checks for existence of the block.
    Epoch endEpoch = STFLib.getEpochForBlock(_end);

    require(startEpoch == endEpoch, Errors.Rollup__StartAndEndNotSameEpoch(startEpoch, endEpoch));

    Epoch currentEpoch = Timestamp.wrap(block.timestamp).epochFromTimestamp();

    require(
      startEpoch.isAcceptingProofsAtEpoch(currentEpoch),
      Errors.Rollup__PastDeadline(startEpoch.toDeadlineEpoch(), currentEpoch)
    );

    // By making sure that the previous block is in another epoch, we know that we were
    // at the start.
    Epoch parentEpoch = STFLib.getEpochForBlock(_start - 1);

    require(startEpoch > Epoch.wrap(0) || _start == 1, Errors.Rollup__InvalidFirstEpochProof());

    bool isStartOfEpoch = _start == 1 || parentEpoch <= startEpoch - Epoch.wrap(1);
    require(isStartOfEpoch, Errors.Rollup__StartIsNotFirstBlockOfEpoch());

    bool isStartBuildingOnProven = _start - 1 <= rollupStore.tips.getProvenBlockNumber();
    require(isStartBuildingOnProven, Errors.Rollup__StartIsNotBuildingOnProven());

    bool claimedNumBlocksInEpoch = _end - _start + 1 <= Constants.AZTEC_MAX_EPOCH_DURATION;
    require(
      claimedNumBlocksInEpoch, Errors.Rollup__TooManyBlocksInEpoch(Constants.AZTEC_MAX_EPOCH_DURATION, _end - _start)
    );

    return endEpoch;
  }

  /**
   * @notice Verifies the validity proof and batched blob proof for an epoch
   *
   * @dev Performs the core cryptographic verification by:
   *      1. Validating the batched blob proof using EIP-4844 point evaluation precompile
   *      2. Assembling the public inputs for the root rollup circuit
   *      3. Verifying the validity proof against the assembled public inputs using the configured verifier
   *
   * @dev Errors Thrown:
   *      - Rollup__InvalidBlobProof: Batched blob proof verification failed
   *      - Rollup__InvalidProof: validity proof verification failed
   *      - Rollup__InvalidPreviousArchive: Previous archive root mismatch in public inputs
   *      - Rollup__InvalidArchive: End archive root mismatch in public inputs
   *
   * @param _args The epoch proof submission arguments containing proof data and public inputs
   * @return True if both blob proof and validity proof verification succeed
   */
  function verifyEpochRootProof(SubmitEpochRootProofArgs calldata _args) private view returns (bool) {
    RollupStore storage rollupStore = STFLib.getStorage();

    BlobLib.validateBatchedBlob(_args.blobInputs);

    bytes32[] memory publicInputs =
      getEpochProofPublicInputs(_args.start, _args.end, _args.args, _args.fees, _args.blobInputs);

    require(rollupStore.config.epochProofVerifier.verify(_args.proof, publicInputs), Errors.Rollup__InvalidProof());

    return true;
  }

  /**
   * @notice Converts a BLS12 field element from bytes32 to a nr BigNum type
   *
   * @dev The nr bignum type for BLS12 fields is encoded as 3 nr fields - see blob_public_inputs.ts:
   *      firstLimb = last 15 bytes;
   *      secondLimb = bytes 2 -> 17;
   *      thirdLimb = first 2 bytes;
   *      Used when verifying epoch proofs to gather blob specific public inputs.
   * @param _input - The field in bytes32
   */
  function bytes32ToBigNum(bytes32 _input)
    private
    pure
    returns (bytes32 firstLimb, bytes32 secondLimb, bytes32 thirdLimb)
  {
    firstLimb = bytes32(uint256(uint120(bytes15(_input << 136))));
    secondLimb = bytes32(uint256(uint120(bytes15(_input << 16))));
    thirdLimb = bytes32(uint256(uint16(bytes2(_input))));
  }

  /**
   * @notice Converts an Ethereum address to a field element for circuit public inputs
   *
   * @dev Addresses are 20 bytes (160 bits) and need to be converted to 32-byte field elements
   *      for use as public inputs in the rollup circuits. The conversion zero-pads the address
   *      to fit the field element format.
   *
   * @param _a The Ethereum address to convert
   * @return The address as a bytes32 field element
   */
  function addressToField(address _a) private pure returns (bytes32) {
    return bytes32(uint256(uint160(_a)));
  }
}


// File: lib/l1-contracts/src/core/libraries/rollup/InvalidateLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {IRollupCore, RollupStore} from "@aztec/core/interfaces/IRollup.sol";
import {CompressedTempBlockLog} from "@aztec/core/libraries/compressed-data/BlockLog.sol";
import {ChainTipsLib, CompressedChainTips} from "@aztec/core/libraries/compressed-data/Tips.sol";
import {Errors} from "@aztec/core/libraries/Errors.sol";
import {Signature, AttestationLib, CommitteeAttestations} from "@aztec/core/libraries/rollup/AttestationLib.sol";
import {STFLib} from "@aztec/core/libraries/rollup/STFLib.sol";
import {ValidatorSelectionLib} from "@aztec/core/libraries/rollup/ValidatorSelectionLib.sol";
import {Timestamp, Slot, Epoch, TimeLib} from "@aztec/core/libraries/TimeLib.sol";
import {CompressedSlot, CompressedTimeMath} from "@aztec/shared/libraries/CompressedTimeMath.sol";
import {ECDSA} from "@oz/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@oz/utils/cryptography/MessageHashUtils.sol";

/**
 * @title InvalidateLib
 * @author Aztec Labs
 * @notice Library responsible for handling the invalidation of L2 blocks with incorrect attestations in the Aztec
 * rollup.
 *
 * @dev This library implements the invalidation mechanism that allows anyone to remove invalid blocks from the
 *      pending chain. An invalid block is one without proper attestations.
 *
 *      The invalidation system addresses two main types of attestation failures:
 *      1. Bad attestation signatures: When committee members provide invalid signatures
 *      2. Insufficient attestations: When a block doesn't meet the required >2/3 committee threshold
 *
 *      Key invariants:
 *      - Only pending (unproven) blocks can be invalidated
 *      - Block must exist in the pending chain (between proven tip and pending tip)
 *      - Invalid blocks and all subsequent blocks are removed from the pending chain
 *
 *      Security model:
 *      - Anyone can call invalidation functions (permissionless)
 *      - No economic incentive (rebate) is provided for calling these functions
 *      - Expected to be called by next proposer, then committee members, then any validator as fallback
 *      - Invalidation reverts the pending chain tip to the block immediately before the invalid one
 *
 *      Integration with the rollup system:
 *      - Works with STFLib for storage access and chain state management
 *      - Uses ValidatorSelectionLib to verify committee commitments
 *      - Validates against TempBlockLog storage for block metadata
 *      - Emits BlockInvalidated events via IRollupCore interface
 *
 *      This invalidation mechanism ensures that even though attestations are not fully validated on-chain
 *      during block proposal (to save gas), invalid attestations can be challenged and removed after the fact,
 *      maintaining the security of the rollup while optimizing for efficient block production.
 *
 *      Note that attestations are validated during the proof submission, but not at every propose call.
 */
library InvalidateLib {
  using TimeLib for Timestamp;
  using TimeLib for Slot;
  using TimeLib for Epoch;
  using ChainTipsLib for CompressedChainTips;
  using AttestationLib for CommitteeAttestations;
  using MessageHashUtils for bytes32;
  using CompressedTimeMath for CompressedSlot;

  /**
   * @notice Invalidates a block containing an invalid attestation
   * @dev Anyone can call this function to remove blocks with invalid attestations.
   *
   *      There are two cases where an individual attestation might be invalid:
   *      1. The attestation is a signature that does not recover to the address from the committee
   *      2. The attestation is an address, that does not match the address from the committee
   *
   *      Upon successful validation of the invalid attestation, the block and all subsequent pending
   *      blocks are removed from the chain by resetting the pending tip to the previous valid block.
   *
   *      No economic rebate is provided for calling this function.
   *
   * @param _blockNumber The L2 block number to invalidate (must be in pending chain)
   * @param _attestations The attestations that were submitted with the block (must match stored hash)
   * @param _committee The committee members for the block's epoch (must match stored computed commitment)
   * @param _invalidIndex The index in the committee/attestations array of the invalid attestation
   *
   * @custom:reverts Errors.Rollup__BlockNotInPendingChain If block number is beyond pending tip
   * @custom:reverts Errors.Rollup__BlockAlreadyProven If block number is already proven
   * @custom:reverts Errors.Rollup__InvalidAttestations If provided attestations don't match stored hash
   * @custom:reverts Errors.ValidatorSelection__InvalidCommitteeCommitment If committee doesn't match stored commitment
   * @custom:reverts Rollup__InvalidAttestationIndex if the _invalidIndex is beyond the committee
   * @custom:reverts Errors.Rollup__AttestationsAreValid If the attestation at invalidIndex is actually valid
   */
  function invalidateBadAttestation(
    uint256 _blockNumber,
    CommitteeAttestations memory _attestations,
    address[] memory _committee,
    uint256 _invalidIndex
  ) internal {
    (bytes32 digest, uint256 committeeSize) = _validateInvalidationInputs(_blockNumber, _attestations, _committee);
    require(_invalidIndex < committeeSize, Errors.Rollup__InvalidAttestationIndex());

    address recovered;

    // Verify that the attestation at invalidIndex does not match the the expected attestation
    // i.e., either recover the address directly from the attestations if no signature
    // or recover the address from the signature if there is a signature.
    // Then take the recovered address and check it against the committee
    if (!_attestations.isSignature(_invalidIndex)) {
      recovered = _attestations.getAddress(_invalidIndex);
    } else {
      Signature memory signature = _attestations.getSignature(_invalidIndex);
      // We use `tryRecover` instead of `recover` since we want improper signatures to return `address(0)` rather than
      // revert. Since `address(0)` is not allowed as an attester, this will cause the recovered address to not match
      // the committee data.
      (recovered,,) = ECDSA.tryRecover(digest, signature.v, signature.r, signature.s);
    }

    require(recovered != _committee[_invalidIndex], Errors.Rollup__AttestationsAreValid());

    _invalidateBlock(_blockNumber);
  }

  /**
   * @notice Invalidates a block that doesn't meet the required >2/3 committee attestation threshold
   * @dev Anyone can call this function to remove blocks with insufficient valid attestations.
   *
   *      The function counts the number of signature attestations (as opposed to address attestations) and
   *      compares against the required threshold of (committeeSize * 2 / 3) + 1. If insufficient signatures
   *      are present, the block and all subsequent pending blocks are removed from the chain.
   *
   *      No economic rebate is provided for calling this function.
   *
   * @param _blockNumber The L2 block number to invalidate (must be in pending chain)
   * @param _attestations The attestations that were submitted with the block (must match stored hash)
   * @param _committee The committee members for the block's epoch (must match stored commitment)
   *
   * @custom:reverts Errors.Rollup__BlockNotInPendingChain If block number is beyond pending tip
   * @custom:reverts Errors.Rollup__BlockAlreadyProven If block number is already proven
   * @custom:reverts Errors.Rollup__InvalidAttestations If provided attestations don't match stored hash
   * @custom:reverts Errors.ValidatorSelection__InvalidCommitteeCommitment If committee doesn't match stored commitment
   * @custom:reverts Errors.ValidatorSelection__InsufficientAttestations If the attestations actually meet the threshold
   */
  function invalidateInsufficientAttestations(
    uint256 _blockNumber,
    CommitteeAttestations memory _attestations,
    address[] memory _committee
  ) internal {
    (, uint256 committeeSize) = _validateInvalidationInputs(_blockNumber, _attestations, _committee);

    uint256 signatureCount = 0;
    for (uint256 i = 0; i < committeeSize; ++i) {
      if (_attestations.isSignature(i)) {
        signatureCount++;
      }
    }

    // Calculate required threshold (2/3 + 1)
    uint256 requiredSignatures = (committeeSize << 1) / 3 + 1; // committeeSize * 2 / 3 + 1

    // Ensure the number of valid signatures is actually insufficient
    require(
      signatureCount < requiredSignatures,
      Errors.ValidatorSelection__InsufficientAttestations(requiredSignatures, signatureCount)
    );

    _invalidateBlock(_blockNumber);
  }

  /**
   * @notice Common validation logic shared by all invalidation functions
   * @dev Performs validation checks to ensure invalidation calls are legitimate and target valid blocks.
   *      This function establishes the foundation for all invalidation operations by verifying:
   *
   *      1. Block existence and state: The target block must be in the pending chain (after the proven tip
   *         but not beyond the pending tip). Proven blocks cannot be invalidated as they are final.
   *
   *      2. Attestation integrity: The provided attestations must exactly match the hash stored when the
   *         block was originally proposed. This prevents manipulation of attestation data.
   *
   *      3. Committee authenticity: The provided committee addresses must match the commitment stored for
   *         the block's epoch. This ensures invalidation is based on the actual committee that should have
   *         attested to the block.
   *
   *      4. Signature context: Computes the digest that committee members were expected to sign, enabling
   *         proper signature verification in calling functions.
   *
   * @param _blockNumber The L2 block number being validated for invalidation
   * @param _attestations The attestations provided for validation
   * @param _committee The committee members for the block's epoch
   * @return digest The payload digest that committee members signed
   * @return committeeSize The number of committee members for the epoch
   *
   * @custom:reverts Errors.Rollup__BlockNotInPendingChain If block is beyond the current pending tip
   * @custom:reverts Errors.Rollup__BlockAlreadyProven If block has already been proven and is final
   * @custom:reverts Errors.Rollup__InvalidAttestations If attestations hash doesn't match stored value
   * @custom:reverts Errors.ValidatorSelection__InvalidCommitteeCommitment If committee hash doesn't match stored
   * commitment
   */
  function _validateInvalidationInputs(
    uint256 _blockNumber,
    CommitteeAttestations memory _attestations,
    address[] memory _committee
  ) private returns (bytes32, uint256) {
    RollupStore storage rollupStore = STFLib.getStorage();

    // Block must be in the pending chain
    require(_blockNumber <= rollupStore.tips.getPendingBlockNumber(), Errors.Rollup__BlockNotInPendingChain());

    // But not yet proven
    require(_blockNumber > rollupStore.tips.getProvenBlockNumber(), Errors.Rollup__BlockAlreadyProven());

    // Get the stored block data
    CompressedTempBlockLog storage blockLog = STFLib.getStorageTempBlockLog(_blockNumber);

    // Verify that the provided attestations match the stored hash
    bytes32 providedAttestationsHash = keccak256(abi.encode(_attestations));
    require(providedAttestationsHash == blockLog.attestationsHash, Errors.Rollup__InvalidAttestations());

    // Get the epoch for the block's slot to verify committee
    Epoch epoch = blockLog.slotNumber.decompress().epochFromSlot();

    // Get and verify the committee commitment
    (bytes32 committeeCommitment, uint256 committeeSize) = ValidatorSelectionLib.getCommitteeCommitmentAt(epoch);
    bytes32 providedCommitteeCommitment = keccak256(abi.encode(_committee));
    require(
      committeeCommitment == providedCommitteeCommitment,
      Errors.ValidatorSelection__InvalidCommitteeCommitment(providedCommitteeCommitment, committeeCommitment)
    );

    // Get the digest of the payload that was signed by the committee
    bytes32 digest = blockLog.payloadDigest.toEthSignedMessageHash();

    return (digest, committeeSize);
  }

  /**
   * @notice Helper that invalidates a block by rolling back the pending chain to the previous valid block
   * @dev This function implements the core invalidation logic by updating the chain tips to remove
   *      the invalid block and all subsequent blocks from the pending chain. The rollback is atomic
   *      and immediately takes effect, preventing any further operations on the invalidated blocks.
   *
   *      The invalidation works by:
   *      1. Setting the pending block number to (_blockNumber - 1)
   *      2. Emitting a BlockInvalidated event for external observers
   *
   *      This approach ensures that when the next valid block is proposed, it will build on the
   *      last remaining valid block, effectively removing the invalid block and any blocks that
   *      were built on top of it.
   *
   *      Note: This function does not clean up the storage for invalidated blocks (archive roots,
   *      temp block logs, etc.) as they may be overwritten by future valid blocks at the same numbers.
   *
   * @param _blockNumber The block number to invalidate
   */
  function _invalidateBlock(uint256 _blockNumber) private {
    RollupStore storage rollupStore = STFLib.getStorage();
    rollupStore.tips = rollupStore.tips.updatePendingBlockNumber(_blockNumber - 1);
    emit IRollupCore.BlockInvalidated(_blockNumber);
  }
}


// File: lib/l1-contracts/src/core/slashing/TallySlashingProposer.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
// solhint-disable comprehensive-interface
pragma solidity >=0.8.27;

import {ISlasher, SlasherFlavor} from "@aztec/core/interfaces/ISlasher.sol";
import {IValidatorSelection} from "@aztec/core/interfaces/IValidatorSelection.sol";
import {Errors} from "@aztec/core/libraries/Errors.sol";
import {SlashPayloadLib} from "@aztec/core/libraries/SlashPayloadLib.sol";
import {SlashRound, CompressedSlashRound, CompressedSlashRoundMath} from "@aztec/core/libraries/SlashRoundLib.sol";
import {IPayload} from "@aztec/governance/interfaces/IPayload.sol";
import {SlashPayloadCloneable} from "@aztec/periphery/SlashPayloadCloneable.sol";
import {CompressedSlot, CompressedTimeMath} from "@aztec/shared/libraries/CompressedTimeMath.sol";
import {SignatureLib, Signature} from "@aztec/shared/libraries/SignatureLib.sol";
import {Slot, Epoch} from "@aztec/shared/libraries/TimeMath.sol";
import {Clones} from "@oz/proxy/Clones.sol";
import {EIP712} from "@oz/utils/cryptography/EIP712.sol";
import {SafeCast} from "@oz/utils/math/SafeCast.sol";

/**
 * @title TallySlashingProposer
 * @author Aztec Labs
 * @notice Tally-based slashing proposer that aggregates validator votes to determine which validators should be
 * slashed
 *
 * @dev This contract implements a voting-based slashing mechanism where block proposers signal their intent to slash
 *      validators from past epochs. The system operates in rounds, with each round corresponding to a time period where
 *      votes are collected from proposers to determine which validators should be slashed.
 *
 *      Key concepts:
 *      - Rounds: Time periods during which votes are collected (measured in slots, multiple of epochs)
 *      - Voting: Block proposers submit encoded votes indicating which validators should be slashed and by how much
 *      - Quorum: Minimum number of votes required in a round to trigger slashing of a specific validator
 *      - Execution Delay: Time that must pass after a round ends before its slashing can be executed (allows vetoing)
 *      - Slash Offset: How many rounds in the past to look when determining which validators to slash
 *
 *      How the system works:
 *      1. Time is divided into rounds (ROUND_SIZE slots each).
 *      2. During each round, block proposers can submit votes indicating which validators from the epochs that span
 *         SLASH_OFFSET_IN_ROUNDS rounds ago should be slashed.
 *      3. Votes are encoded as bytes where each 2-bit pair represents the slash amount (0-3 slash units) for
 *         the corresponding validator slashed in the round.
 *      4. After a round ends, there is an execution delay period for review so the VETOER in the Slasher can veto the
 *         expected payload address if needed.
 *      5. Once the delay passes, anyone can call executeRound() to tally votes and execute slashing.
 *      6. Validators that reach the quorum threshold are slashed by the specified amount. We consider a vote for
 *         slashing N units as also a vote for slashing N-1, N-2, ..., 1 units. We slash for the largest amount that
 *         reaches quorum.
 *
 *      About SLASH_OFFSET_IN_ROUNDS:
 *      - This offset gives us time to detect an offense and then vote on it in a later
 *        round. For instance, an `VALID_EPOCH_PRUNED` offense for epoch N is only triggered after
 *        `PROOF_SUBMISSION_WINDOW` epochs. Consider the following:
 *        - Epoch 1 is valid
 *        - At the end of epoch 3, the proof for 1 has not landed, so epoch 1 is pruned
 *        - Network decides to slash the committee of epoch 1
 *        - This means that only starting from epoch 4 we should be voting for slashing the committee of epoch 1
 *      - In terms of voting, this parameter means that in round R we are voting for the committee of epochs starting
 *        from (R - SLASH_OFFSET_IN_ROUNDS) * ROUND_SIZE_IN_EPOCHS.
 *      - For example, with SLASH_OFFSET_IN_ROUNDS=2, ROUND_SIZE=10, and EPOCH_DURATION=2
 *        - In round 4, we are voting for the committee of epochs starting from (4 - 2) * 10 = 20 (i.e., epochs 20-29)
 *
 *      Considerations:
 *      - Only the designated proposer for each slot can submit votes
 *      - Votes are signed using EIP-712
 *      - Votes include slot numbers to prevent replay attacks
 *      - Committee commitments are verified against on-chain data
 *      - Rounds have a lifetime limit
 *      - Uses circular storage to limit memory usage while maintaining recent round data
 *
 *      Integration with Aztec system:
 *      - Connects to the main Rollup contract (INSTANCE) to get proposer information and committee data
 *      - Uses the Slasher contract to execute actual slashing operations
 *      - Coordinates with validator selection of the Rollup instance to identify which validators should be slashed
 *      - Supports the Rollup's security model by enabling punishment of misbehaving validators
 *
 *      Parameters and configuration:
 *      - QUORUM: Minimum votes needed to slash a validator
 *      - ROUND_SIZE: Number of slots per voting round
 *      - EXECUTION_DELAY_IN_ROUNDS: Rounds to wait before allowing execution
 *      - LIFETIME_IN_ROUNDS: Maximum age of rounds that can still be executed
 *      - SLASH_OFFSET_IN_ROUNDS: How far back to look for validators to slash
 *      - SLASH_AMOUNT_SMALL/MEDIUM/LARGE: Specific amounts for each slash unit level
 *      - COMMITTEE_SIZE: Number of validators per committee
 */
contract TallySlashingProposer is EIP712 {
  using SignatureLib for Signature;
  using CompressedTimeMath for CompressedSlot;
  using CompressedTimeMath for Slot;
  using CompressedSlashRoundMath for CompressedSlashRound;
  using CompressedSlashRoundMath for SlashRound;
  using Clones for address;
  using SlashPayloadLib for address[];

  /**
   * @notice Contains metadata about a slashing round stored in uncompressed format
   * @dev Used for in-memory operations and as the return type for getRoundData()
   * @param roundNumber The actual round number (used to detect stale data in circular storage)
   * @param voteCount Number of votes collected in this round so far
   * @param lastVoteSlot The most recent slot in which a vote was cast for this round
   * @param executed Whether this round has been executed and slashing has occurred
   */
  struct RoundData {
    SlashRound roundNumber;
    uint256 voteCount;
    Slot lastVoteSlot;
    bool executed;
  }

  /**
   * @notice Compressed version of RoundData optimized for storage efficiency (fits in 32 bytes)
   * @dev Used in the circular storage buffer to minimize gas costs for storage operations
   * @param roundNumber Compressed round number for staleness detection
   * @param lastVoteSlot Compressed slot number of the last vote
   * @param voteCount Number of votes (max 65535, must fit MAX_ROUND_SIZE constraint)
   * @param executed Whether this round has been executed
   */
  struct CompressedRoundData {
    CompressedSlashRound roundNumber;
    CompressedSlot lastVoteSlot;
    uint16 voteCount;
    bool executed;
  }

  /**
   * @notice Contains all vote data for a single round
   * @dev Stores up to MAX_ROUND_SIZE votes as fixed-size arrays. Each vote encodes slash amounts
   *      for all validators in the round using 2 bits per validator.
   * @param votes Array of encoded vote data, one entry per proposer vote in the round
   *         Each vote is stored as fixed-size bytes32 chunks, to avoid the overhead of an extra SLOAD/SSTORE operation
   *         just to load/write the length of the array, which we already know.
   *         Vote size = COMMITTEE_SIZE * ROUND_SIZE_IN_EPOCHS / 4 bytes
   *         Number of bytes32 slots needed = ceil(voteSize / 32)
   *         Note that we check the vote size in the constructor to avoid issues
   */
  struct RoundVotes {
    bytes32[4][1024] votes; // Assuming max 4 slots (128 bytes) per vote
  }

  /**
   * @notice Represents a slashing action to be executed against a specific validator
   * @dev Used to package slashing decisions for execution by the Slasher contract
   * @param validator The address of the validator to be slashed
   * @param slashAmount The amount of stake to slash from the validator (in wei)
   */
  struct SlashAction {
    address validator;
    uint256 slashAmount;
  }

  /**
   * @notice EIP-712 type hash for the Vote struct used in signature verification
   * @dev Defines the structure: Vote(uint256 slot,bytes votes) for EIP-712 signing
   */
  bytes32 public constant VOTE_TYPEHASH = keccak256("Vote(bytes votes,uint256 slot)");

  /**
   * @notice Type of slashing proposer (either Tally or Empire)
   */
  SlasherFlavor public constant SLASHING_PROPOSER_TYPE = SlasherFlavor.TALLY;

  /**
   * @notice Size of the circular storage buffer for round data
   * @dev Determines how many recent rounds can be kept in storage simultaneously.
   *      Older rounds are overwritten as new rounds are created. Must be larger than
   *      LIFETIME_IN_ROUNDS to prevent data corruption.
   */
  uint256 public constant ROUNDABOUT_SIZE = 128;

  /**
   * @notice Maximum number of votes that can be cast in a single round
   * @dev Hard limit to prevent excessive gas usage and storage requirements.
   *      Also serves as the maximum number of slots per round.
   */
  uint256 public constant MAX_ROUND_SIZE = 1024;

  /**
   * @notice Address of the main rollup contract that this slashing proposer integrates with
   * @dev Used to query current proposers, committee data, and slot information
   */
  address public immutable INSTANCE;

  /**
   * @notice The slasher contract that executes actual slashing operations
   * @dev Receives SlashPayload contracts from this proposer to perform validator punishment
   */
  ISlasher public immutable SLASHER;

  /**
   * @notice The implementation contract for SlashPayload clones
   * @dev Single instance deployed once and used as template for all slash payload clones
   */
  address public immutable SLASH_PAYLOAD_IMPLEMENTATION;

  /**
   * @notice Base amount of stake to slash per slashing unit (in wei)
   * @dev Validators can be voted to be slashed by 1-3 units, multiplied by this base amount
   * @notice Small slash amount for 1 unit votes (in wei)
   */
  uint256 public immutable SLASH_AMOUNT_SMALL;

  /**
   * @notice Medium slash amount for 2 unit votes (in wei)
   */
  uint256 public immutable SLASH_AMOUNT_MEDIUM;

  /**
   * @notice Large slash amount for 3 unit votes (in wei)
   */
  uint256 public immutable SLASH_AMOUNT_LARGE;

  /**
   * @notice Minimum number of votes required to slash a validator
   * @dev Must be greater than ROUND_SIZE/2 to ensure majority agreement
   */
  uint256 public immutable QUORUM;

  /**
   * @notice Number of slots per slashing round
   * @dev Determines the duration of voting periods and must be a multiple of epoch duration
   */
  uint256 public immutable ROUND_SIZE;

  /**
   * @notice Number of validators per committee
   * @dev Used to determine vote encoding length and validator indexing
   */
  uint256 public immutable COMMITTEE_SIZE;

  /**
   * @notice Number of epochs per slashing round
   * @dev Calculated as ROUND_SIZE / epoch duration, determines how many committees are voted on per round
   */
  uint256 public immutable ROUND_SIZE_IN_EPOCHS;

  /**
   * @notice Maximum age in rounds for which a round can still be executed
   * @dev Prevents execution of very old rounds that may no longer be relevant
   */
  uint256 public immutable LIFETIME_IN_ROUNDS;

  /**
   * @notice Number of rounds to wait after a round ends before it can be executed
   * @dev Provides time for review and potential challenges before slashing occurs
   */
  uint256 public immutable EXECUTION_DELAY_IN_ROUNDS;

  /**
   * @notice How many rounds in the past to look when determining which validators to slash
   * @dev During round N, we cannot slash the validators from the epochs of the same round, since the round is not over,
   * and besides we would be asking the current validators to vote to slash themselves. So during round N we look at the
   * epochs spanned during round N - SLASH_OFFSET_IN_ROUNDS. This offset means that the epochs we slash are complete,
   * and also gives nodes time to detect any misbehavior (eg slashing for prunes requires the proof submission window to
   * pass).
   */
  uint256 public immutable SLASH_OFFSET_IN_ROUNDS;

  // Circular mappings of round number to round data and votes
  CompressedRoundData[ROUNDABOUT_SIZE] private roundDatas;
  RoundVotes[ROUNDABOUT_SIZE] private roundVotes;

  /**
   * @notice Emitted when a proposer casts a vote in a slashing round
   * @param round The round number in which the vote was cast
   * @param proposer The address of the proposer who cast the vote
   */
  event VoteCast(SlashRound indexed round, Slot indexed slot, address indexed proposer);

  /**
   * @notice Emitted when a slashing round is executed and validators are slashed
   * @param round The round number that was executed
   * @param slashCount The number of validators that were slashed in this round
   */
  event RoundExecuted(SlashRound indexed round, uint256 slashCount);

  /**
   * @notice Initializes the TallySlashingProposer with configuration parameters
   * @dev Sets up all the voting and slashing parameters and validates their correctness.
   *      The constructor enforces several important invariants to ensure the system operates correctly.
   *
   * @param _instance The address of the rollup contract that this slashing proposer will interact with
   * @param _slasher The slasher contract that will execute the actual slashing operations
   * @param _quorum The minimum number of votes required to slash a validator (must be > ROUND_SIZE/2 and <= ROUND_SIZE)
   * @param _roundSize The number of slots in each voting round (must be > 1 and < MAX_ROUND_SIZE)
   * @param _lifetimeInRounds The maximum age in rounds for which a round can still be executed (must be >
   * _executionDelayInRounds and < ROUNDABOUT_SIZE)
   * @param _executionDelayInRounds The number of rounds to wait after a round ends before it can be executed (provides
   * time for review)
   * @param _slashAmounts Array of 3 slash amounts [small, medium, large] for 1, 2, 3 unit votes (all must be > 0)
   * @param _committeeSize The number of validators in each committee (must be > 0)
   * @param _epochDuration The number of slots in each epoch (used to calculate ROUND_SIZE_IN_EPOCHS)
   * @param _slashOffsetInRounds How many rounds in the past to look when determining which validators to slash (must be
   * > 0)
   */
  constructor(
    address _instance,
    ISlasher _slasher,
    uint256 _quorum,
    uint256 _roundSize,
    uint256 _lifetimeInRounds,
    uint256 _executionDelayInRounds,
    uint256[3] memory _slashAmounts,
    uint256 _committeeSize,
    uint256 _epochDuration,
    uint256 _slashOffsetInRounds
  ) EIP712("TallySlashingProposer", "1") {
    INSTANCE = _instance;
    SLASHER = _slasher;
    SLASH_AMOUNT_SMALL = _slashAmounts[0];
    SLASH_AMOUNT_MEDIUM = _slashAmounts[1];
    SLASH_AMOUNT_LARGE = _slashAmounts[2];
    QUORUM = _quorum;
    ROUND_SIZE = _roundSize;
    ROUND_SIZE_IN_EPOCHS = _roundSize / _epochDuration;
    COMMITTEE_SIZE = _committeeSize;
    LIFETIME_IN_ROUNDS = _lifetimeInRounds;
    EXECUTION_DELAY_IN_ROUNDS = _executionDelayInRounds;
    SLASH_OFFSET_IN_ROUNDS = _slashOffsetInRounds;

    // Deploy the SlashPayloadCloneable implementation contract once
    SLASH_PAYLOAD_IMPLEMENTATION = address(new SlashPayloadCloneable{salt: bytes32(bytes20(uint160(address(this))))}());

    require(
      SLASH_OFFSET_IN_ROUNDS > 0, Errors.TallySlashingProposer__SlashOffsetMustBeGreaterThanZero(SLASH_OFFSET_IN_ROUNDS)
    );
    require(
      ROUND_SIZE_IN_EPOCHS * _epochDuration == ROUND_SIZE,
      Errors.TallySlashingProposer__RoundSizeMustBeMultipleOfEpochDuration(ROUND_SIZE, _epochDuration)
    );
    require(QUORUM > 0, Errors.TallySlashingProposer__QuorumMustBeGreaterThanZero());
    require(ROUND_SIZE > 1, Errors.TallySlashingProposer__InvalidQuorumAndRoundSize(QUORUM, ROUND_SIZE));
    require(QUORUM > ROUND_SIZE / 2, Errors.TallySlashingProposer__InvalidQuorumAndRoundSize(QUORUM, ROUND_SIZE));
    require(QUORUM <= ROUND_SIZE, Errors.TallySlashingProposer__InvalidQuorumAndRoundSize(QUORUM, ROUND_SIZE));
    require(_slashAmounts[0] <= _slashAmounts[1], Errors.TallySlashingProposer__InvalidSlashAmounts(_slashAmounts));
    require(_slashAmounts[1] <= _slashAmounts[2], Errors.TallySlashingProposer__InvalidSlashAmounts(_slashAmounts));
    require(
      LIFETIME_IN_ROUNDS > EXECUTION_DELAY_IN_ROUNDS,
      Errors.TallySlashingProposer__LifetimeMustBeGreaterThanExecutionDelay(
        LIFETIME_IN_ROUNDS, EXECUTION_DELAY_IN_ROUNDS
      )
    );
    require(
      LIFETIME_IN_ROUNDS < ROUNDABOUT_SIZE,
      Errors.TallySlashingProposer__LifetimeMustBeLessThanRoundabout(LIFETIME_IN_ROUNDS, ROUNDABOUT_SIZE)
    );
    require(
      ROUND_SIZE_IN_EPOCHS > 0,
      Errors.TallySlashingProposer__RoundSizeInEpochsMustBeGreaterThanZero(ROUND_SIZE_IN_EPOCHS)
    );
    require(ROUND_SIZE < MAX_ROUND_SIZE, Errors.TallySlashingProposer__RoundSizeTooLarge(ROUND_SIZE, MAX_ROUND_SIZE));
    require(COMMITTEE_SIZE > 0, Errors.TallySlashingProposer__CommitteeSizeMustBeGreaterThanZero(COMMITTEE_SIZE));

    // Validate that vote size doesn't exceed our fixed 4 bytes32 allocation
    // Each vote requires COMMITTEE_SIZE * ROUND_SIZE_IN_EPOCHS / 4 bytes
    // We have allocated 4 bytes32 slots = 128 bytes maximum
    uint256 voteSize = COMMITTEE_SIZE * ROUND_SIZE_IN_EPOCHS / 4;
    require(voteSize <= 128, Errors.TallySlashingProposer__VoteSizeTooBig(voteSize, 128));

    require(
      COMMITTEE_SIZE * ROUND_SIZE_IN_EPOCHS % 4 == 0,
      Errors.TallySlashingProposer__VotesMustBeMultipleOf4(COMMITTEE_SIZE * ROUND_SIZE_IN_EPOCHS)
    );
  }

  /**
   * @notice Submit a vote for slashing validators from SLASH_OFFSET_IN_ROUNDS rounds ago
   * @dev Only the current block proposer can submit votes, enforced via EIP-712 signature verification.
   *      Each byte in the votes encodes slash amounts for 4 validators using 2 bits each (0-3 units each).
   *      The vote includes the current slot number to prevent replay attacks.
   *
   * @param _votes Encoded voting data where each byte represents slash amounts for 4 validators.
   *               Bits 0-1 for first validator, bits 2-3 for second, bits 4-5 for third, bits 6-7 for fourth.
   *               Length must equal (COMMITTEE_SIZE * ROUND_SIZE_IN_EPOCHS) / 4 bytes.
   * @param _sig EIP-712 signature from the current proposer proving authorization to vote.
   *             Signature covers the vote data and current slot number.
   *
   * Emits:
   * - VoteCast: When the vote is successfully recorded
   *
   * Reverts with:
   * - TallySlashingProposer__VotingNotOpen: If current round is less than SLASH_OFFSET_IN_ROUNDS
   * - TallySlashingProposer__InvalidSignature: If signature verification fails
   * - TallySlashingProposer__InvalidVoteLength: If vote data length is incorrect
   * - TallySlashingProposer__VoteAlreadyCastInCurrentSlot: If proposer already voted in this slot
   */
  function vote(bytes calldata _votes, Signature calldata _sig) external {
    Slot slot = _getCurrentSlot();
    SlashRound round = _computeRound(slot);

    // We vote for slashing validators for epochs from SLASH_OFFSET_IN_ROUNDS ago, so in early rounds there is no one to
    // be slashed.
    require(round >= SlashRound.wrap(SLASH_OFFSET_IN_ROUNDS), Errors.TallySlashingProposer__VotingNotOpen(round));

    // Get the current proposer from the rollup - only they can submit votes
    address proposer = _getCurrentProposer();

    // Verify EIP-712 signature (which includes slot to prevent replay attacks)
    bytes32 digest = getVoteSignatureDigest(_votes, slot);
    require(_sig.verify(proposer, digest), Errors.TallySlashingProposer__InvalidSignature());

    // Each byte encodes 4 validators (2 bits each), so each validator is represented as 2 bits in the byte array.
    uint256 expectedLength = COMMITTEE_SIZE * ROUND_SIZE_IN_EPOCHS / 4;
    require(
      _votes.length == expectedLength, Errors.TallySlashingProposer__InvalidVoteLength(expectedLength, _votes.length)
    );

    // Get the round data for the current round
    RoundData memory roundData = _getRoundData(round, round);

    // Check if a vote has already been cast in the current slot
    require(roundData.lastVoteSlot < slot, Errors.TallySlashingProposer__VoteAlreadyCastInCurrentSlot(slot));

    // Store the vote for this round
    uint256 voteCount = roundData.voteCount;
    _storeVoteData(round, voteCount, _votes);

    // Increment the vote count for this round (all other fields remain unchanged)
    _setRoundData(round, slot, voteCount + 1, roundData.executed);

    emit VoteCast(round, slot, proposer);
  }

  /**
   * @notice Execute the slashing round by tallying votes and executing slashes for validators that reached quorum
   * @dev Can be called by anyone once a round has passed its execution delay but is still within its lifetime.
   *      The function tallies all votes cast during the round, identifies validators that reached the quorum threshold,
   *      and executes slashing by deploying a SlashPayload contract and calling the Slasher.
   *
   * @param _round The round number to execute (must be ready for execution based on timing constraints)
   * @param _committees Array of validator committees slashed for each epoch in the round being executed.
   *                   Must contain exactly ROUND_SIZE_IN_EPOCHS committees. Only committees with slashed
   *                   validators will have their commitments verified against on-chain data.
   *
   * Emits:
   * - RoundExecuted: When the round execution completes, regardless of whether any slashing occurred
   *
   * Reverts with:
   * - TallySlashingProposer__RoundAlreadyExecuted: If the round has already been executed
   * - TallySlashingProposer__RoundNotComplete: If the round is not yet ready for execution or has expired
   * - TallySlashingProposer__InvalidCommitteeCommitment: If any committee commitment doesn't match on-chain data
   * - TallySlashingProposer__InvalidNumberOfCommittees: If the number of committees doesn't match
   * ROUND_SIZE_IN_EPOCHS
   */
  function executeRound(SlashRound _round, address[][] calldata _committees) external {
    // Get round data to check if already executed
    SlashRound currentRound = getCurrentRound();
    RoundData memory roundData = _getRoundData(_round, currentRound);
    require(!roundData.executed, Errors.TallySlashingProposer__RoundAlreadyExecuted(_round));

    // Ensure enough time has passed (execution delay) but not too much (lifetime)
    require(_isRoundReadyToExecute(_round, currentRound), Errors.TallySlashingProposer__RoundNotComplete(_round));

    // Get the slash actions by tallying votes and which committees have slashes
    (SlashAction[] memory actions, bool[] memory committeesWithSlashes) = _tally(roundData, _committees);

    // Only verify committees that have slashed validators
    unchecked {
      uint256 length = committeesWithSlashes.length;
      for (uint256 i; i < length; ++i) {
        if (!committeesWithSlashes[i]) {
          continue;
        }

        // Check committee commitments against the stored on-chain data
        bytes32 commitment = _computeCommitteeCommitment(_committees[i]);
        Epoch epochNumber = getSlashTargetEpoch(_round, i);
        require(
          commitment == _getCommitteeCommitment(epochNumber), Errors.TallySlashingProposer__InvalidCommitteeCommitment()
        );
      }
    }

    // Mark round as executed to prevent re-execution
    // We set this flag before actually slashing to avoid re-entrancy issues
    _setRoundData(_round, roundData.lastVoteSlot, roundData.voteCount, /*executed=*/ true);

    // Execute slashes if any were determined
    if (actions.length > 0) {
      // Deploy payload contract and execute slashes
      IPayload slashPayload = _deploySlashPayload(_round, actions);
      SLASHER.slash(slashPayload);
    }

    emit RoundExecuted(_round, actions.length);
  }

  /**
   * @notice Load committees for all epochs to be potentially slashed in a round from the rollup instance
   * @dev This is an expensive call. It is not marked as view since `getEpochCommittee` may modify rollup state.
   *      If `getEpochCommittee` throws (eg committee not yet formed), an empty committee is returned for that epoch.
   * @param _round The round number to load committees for
   * @return committees Array of committees, one for each epoch in the round (may contain empty arrays for early epochs)
   */
  function getSlashTargetCommittees(SlashRound _round) external returns (address[][] memory committees) {
    committees = new address[][](ROUND_SIZE_IN_EPOCHS);

    IValidatorSelection rollup = IValidatorSelection(INSTANCE);
    unchecked {
      for (uint256 epochIndex; epochIndex < ROUND_SIZE_IN_EPOCHS; ++epochIndex) {
        Epoch epoch = getSlashTargetEpoch(_round, epochIndex);
        try rollup.getEpochCommittee(epoch) returns (address[] memory committee) {
          committees[epochIndex] = committee;
        } catch {
          committees[epochIndex] = new address[](0);
        }
      }
    }

    return committees;
  }

  /**
   * @notice Get the tally results for a specific round, showing which validators would be slashed
   * @dev This function is intended for off-chain querying and analysis of voting results.
   *      It uses transient storage when calling getEpochCommittee on the rollup contract.
   *      Returns the same slash actions that would be executed if executeRound() were called for this round.
   *
   * @param _round The round number to analyze and return tally results for
   * @param _committees The list of committees to consider for the tally (get them via `getSlashTargetCommittees`)
   * @return actions Array of SlashAction structs containing validator addresses and slash amounts
   *                for all validators that reached the quorum threshold in this round
   */
  function getTally(SlashRound _round, address[][] calldata _committees) external view returns (SlashAction[] memory) {
    // Get the round data for the specified round
    RoundData memory roundData = _getRoundData(_round, getCurrentRound());

    // Tally votes and return slash actions
    (SlashAction[] memory actions,) = _tally(roundData, _committees);
    return actions;
  }

  /**
   * @notice Get the deterministic address where a slash payload would be deployed for given actions
   * @dev Uses CREATE2 to predict the deployment address based on the round number and slash actions.
   *      Returns zero address if no actions are provided. The address is deterministic and will be
   *      the same across multiple calls with identical parameters.
   *
   * @param _round The round number that will be mixed into the CREATE2 salt
   * @param _actions Array of SlashAction structs containing validator addresses and slash amounts
   * @return The predicted deployment address of the SlashPayload contract, or zero address if no actions
   */
  function getPayloadAddress(SlashRound _round, SlashAction[] memory _actions) external view returns (address) {
    // Return zero address if no actions
    if (_actions.length == 0) {
      return address(0);
    }
    (,,, address predictedAddress) = _preparePayloadDataAndAddress(_round, _actions);
    return predictedAddress;
  }

  /**
   * @notice Get information about a specific slashing round's status and voting data
   * @param _round The round number to retrieve information for
   * @return isExecuted True if the round has already been executed and slashing has occurred
   * @return readyToExecute True if the round is currently ready for execution (past execution delay but within
   * lifetime)
   * @return voteCount The total number of votes that have been cast in this round by proposers
   */
  function getRound(SlashRound _round) external view returns (bool isExecuted, bool readyToExecute, uint256 voteCount) {
    SlashRound currentRound = getCurrentRound();

    // Load round data from the circular storage
    RoundData memory roundData = _getRoundData(_round, currentRound);

    // Check if the round is ready to execute based on current round number
    bool isReady = _isRoundReadyToExecute(_round, currentRound);

    // If we have not written to this round yet, return fresh round data
    if (roundData.roundNumber != _round) {
      return (false, isReady, 0);
    }

    return (roundData.executed, isReady, roundData.voteCount);
  }

  /**
   * @notice Get the votes for a specific `_round` at a specific `_index`
   * @param _round The round number to retrieve votes for
   * @param _index The index to retrieve votes for
   * @return The votes retrieved
   */
  function getVotes(SlashRound _round, uint256 _index) external view returns (bytes memory) {
    uint256 expectedLength = COMMITTEE_SIZE * ROUND_SIZE_IN_EPOCHS / 4;
    bytes32[4] storage voteSlots = _getRoundVotes(_round).votes[_index];
    return _loadVoteDataFromStorage(voteSlots, expectedLength);
  }

  /**
   * @notice Get the current round number based on the current slot from the rollup
   * @dev Calculates the current round by dividing the current slot number by ROUND_SIZE.
   *      This determines which voting round is currently active.
   * @return The current SlashRound number
   */
  function getCurrentRound() public view returns (SlashRound) {
    // Get current slot from the rollup instance
    IValidatorSelection rollup = IValidatorSelection(INSTANCE);
    Slot currentSlot = rollup.getCurrentSlot();
    // Divide slot by round size to get round number
    return SlashRound.wrap(Slot.unwrap(currentSlot) / ROUND_SIZE);
  }

  /**
   * @notice Get the epoch number that will be slashed during a specific round at a given epoch index
   * @dev Calculates which epoch's validators are being voted on for slashing in a given round.
   *      The epoch is determined by looking back SLASH_OFFSET_IN_ROUNDS rounds from the voting round
   *      and then adding the epoch index within that round.
   *
   * @param _round The round number during which voting is taking place
   * @param _epochIndex The index of the epoch within the round (must be 0 to ROUND_SIZE_IN_EPOCHS-1)
   * @return epochNumber The epoch number whose validators will be considered for slashing
   *
   * Reverts with:
   * - TallySlashingProposer__VotingNotOpen: If the round is less than SLASH_OFFSET_IN_ROUNDS
   */
  function getSlashTargetEpoch(SlashRound _round, uint256 _epochIndex) public view returns (Epoch epochNumber) {
    require(_round >= SlashRound.wrap(SLASH_OFFSET_IN_ROUNDS), Errors.TallySlashingProposer__VotingNotOpen(_round));
    require(
      _epochIndex < ROUND_SIZE_IN_EPOCHS,
      Errors.TallySlashingProposer__InvalidEpochIndex(_epochIndex, ROUND_SIZE_IN_EPOCHS)
    );
    return Epoch.wrap((SlashRound.unwrap(_round) - SLASH_OFFSET_IN_ROUNDS) * ROUND_SIZE_IN_EPOCHS + _epochIndex);
  }

  /**
   * @notice Generate the EIP-712 signature digest for a vote to prevent replay attacks
   * @dev Creates a typed data hash according to EIP-712 standard that includes both the vote data
   *      and the slot number. The slot number inclusion prevents votes from being replayed in
   *      different slots, ensuring each vote is tied to a specific time.
   *
   * @param _votes The encoded vote data that will be signed by the proposer
   * @param _slot The slot number when the vote is being cast (prevents replay attacks)
   * @return The EIP-712 compliant signature digest that should be signed by the proposer
   */
  function getVoteSignatureDigest(bytes calldata _votes, Slot _slot) public view returns (bytes32) {
    return _hashTypedDataV4(keccak256(abi.encode(VOTE_TYPEHASH, keccak256(_votes), Slot.unwrap(_slot))));
  }

  /**
   * @notice Get the address of the validator who is authorized to propose in the current slot
   * @dev Queries the rollup contract to determine which validator has proposing rights.
   *      This is used to verify that vote signatures come from the authorized proposer.
   * @return The address of the current slot's designated proposer
   */
  function _getCurrentProposer() internal returns (address) {
    // Query the rollup for who is allowed to propose in the current slot
    IValidatorSelection rollup = IValidatorSelection(INSTANCE);
    return rollup.getCurrentProposer();
  }

  /**
   * @notice Get the committee commitment from the Rollup.
   * @param _epoch The epoch number
   */
  function _getCommitteeCommitment(Epoch _epoch) internal returns (bytes32) {
    IValidatorSelection rollup = IValidatorSelection(INSTANCE);
    (bytes32 commitment,) = rollup.getEpochCommitteeCommitment(_epoch);
    return commitment;
  }

  /**
   * @notice Deploy a slash payload contract with the given actions
   * @dev Deploys a SlashPayload contract using CREATE2 for deterministic addresses
   * @param _round The round number (mixed into the salt)
   * @param _actions Array of slash actions to encode in the payload
   */
  function _deploySlashPayload(SlashRound _round, SlashAction[] memory _actions) internal returns (IPayload) {
    // Prepare arrays for the SlashPayload constructor and get the predicted address
    (address[] memory validators, uint96[] memory amounts, bytes32 salt, address predictedAddress) =
      _preparePayloadDataAndAddress(_round, _actions);
    // Return existing payload if already deployed
    if (predictedAddress.code.length > 0) {
      return IPayload(predictedAddress);
    }

    // Deploy clone of SlashPayload using EIP-1167 minimal proxy with immutable args
    // Encode the immutable arguments for the clone
    bytes memory immutableArgs = SlashPayloadLib.encodeImmutableArgs(INSTANCE, validators, amounts);

    // Deploy the clone with deterministic address
    address clone = Clones.cloneDeterministicWithImmutableArgs(SLASH_PAYLOAD_IMPLEMENTATION, immutableArgs, salt);

    return IPayload(clone);
  }

  /**
   * @notice Store vote data in fixed-size format
   * @param roundNumber The round to store the vote for
   * @param voteIndex The index of the vote within the round
   * @param voteData The vote data to store
   */
  function _storeVoteData(SlashRound roundNumber, uint256 voteIndex, bytes calldata voteData) internal {
    bytes32[4] storage voteSlots = _getRoundVotes(roundNumber).votes[voteIndex];
    uint256 dataLength = voteData.length;

    // Ensure we don't exceed maximum size
    require(dataLength <= 128, Errors.TallySlashingProposer__VoteSizeTooBig(dataLength, 128));

    unchecked {
      assembly {
        let offset := voteData.offset

        // Store chunk 0 (bytes 0-31)
        if dataLength {
          let chunk := calldataload(offset)
          // For partial chunks, we need to keep data left-aligned in the slot
          // No masking needed since unused bytes are already zero in calldata
          sstore(voteSlots.slot, chunk)
        }

        // Store chunk 1 (bytes 32-63)
        if gt(dataLength, 32) {
          let chunk := calldataload(add(offset, 32))
          sstore(add(voteSlots.slot, 1), chunk)
        }

        // Store chunk 2 (bytes 64-95)
        if gt(dataLength, 64) {
          let chunk := calldataload(add(offset, 64))
          sstore(add(voteSlots.slot, 2), chunk)
        }

        // Store chunk 3 (bytes 96-127)
        if gt(dataLength, 96) {
          let chunk := calldataload(add(offset, 96))
          sstore(add(voteSlots.slot, 3), chunk)
        }
      }
    }
  }

  /**
   * @notice Set round data in the circular storage
   * This function DOES NOT check for round validity or range within the roundabout
   * @param roundNumber The round number to set
   * @param lastVoteSlot The last slot for which a vote was received
   * @param voteCount The number of votes collected so far in this round
   * @param executed Whether this round has been executed
   * @dev This is an internal function that should only be called after verifying the round is valid and within range
   * @dev It updates the round data in the circular storage buffer
   */
  function _setRoundData(SlashRound roundNumber, Slot lastVoteSlot, uint256 voteCount, bool executed) internal {
    roundDatas[SlashRound.unwrap(roundNumber) % ROUNDABOUT_SIZE] = CompressedRoundData({
      roundNumber: roundNumber.compress(),
      lastVoteSlot: lastVoteSlot.compress(),
      voteCount: SafeCast.toUint16(voteCount), // Ensure voteCount fits in uint16
      executed: executed
    });
  }

  /**
   * @notice Tally votes for a specific round and return the slash actions to execute
   * @param _roundData The round data containing votes to tally
   * @param _committees The committees for each epoch in the round
   * @return slashActions Array of slash actions that reached quorum
   * @return committeesWithSlashes Boolean array indicating which committees have at least one slashed validator
   */
  function _tally(RoundData memory _roundData, address[][] calldata _committees)
    internal
    view
    returns (SlashAction[] memory slashActions, bool[] memory committeesWithSlashes)
  {
    // Must have one committee per epoch in the round
    require(
      _committees.length == ROUND_SIZE_IN_EPOCHS,
      Errors.TallySlashingProposer__InvalidNumberOfCommittees(ROUND_SIZE_IN_EPOCHS, _committees.length)
    );

    uint256 voteCount = _roundData.voteCount;

    // No votes cast, return empty array
    if (voteCount == 0) {
      return (new SlashAction[](0), new bool[](ROUND_SIZE_IN_EPOCHS));
    }

    // Pre-calculate total validators to optimize memory allocation
    uint256 totalValidators = COMMITTEE_SIZE * ROUND_SIZE_IN_EPOCHS;

    // Create a voting tally array where each uint256 packs all vote counts for a validator
    // Layout: [0-63: votes for 1 unit][64-127: votes for 2 units][128-191: votes for 3 units][192-255: unused]
    // Each 64-bit segment can store up to 2^64-1 votes
    // Overflow protection: With MAX_ROUND_SIZE=1024, maximum possible votes per validator is 1024,
    // which is well below 2^64-1, preventing any overflow in the packed counters
    uint256[] memory tallyMatrix = new uint256[](totalValidators);

    // Process all votes cast during this round to populate the tally matrix
    _processVotes(_roundData, tallyMatrix, voteCount);

    // Determine which validators reached quorum and return slash actions
    return _determineSlashActions(tallyMatrix, _committees, totalValidators);
  }

  /**
   * @notice Process all votes and populate the tally matrix
   */
  function _processVotes(RoundData memory _roundData, uint256[] memory tallyMatrix, uint256 voteCount) internal view {
    SlashRound roundNumber = _roundData.roundNumber;
    uint256 voteLength = COMMITTEE_SIZE * ROUND_SIZE_IN_EPOCHS / 4;

    // Cache the RoundVotes storage reference to avoid repeated calls
    RoundVotes storage targetRoundVotes = _getRoundVotes(roundNumber);

    unchecked {
      for (uint256 i; i < voteCount; ++i) {
        // Load the i-th votes from this round from storage into memory
        bytes memory currentVote = _loadVoteDataFromStorage(targetRoundVotes.votes[i], voteLength);

        // Process votes 32 bytes at a time
        uint256 j;
        for (; j + 31 < voteLength; j += 32) {
          // Process 32 bytes at once (128 validators)
          _process32BytesVotes(tallyMatrix, currentVote, j);
        }

        // Process remaining bytes one at a time (inlined)
        for (; j < voteLength; ++j) {
          uint256 baseIndex = j << 2; // j * 4 using bit shift
          uint8 currentByte;

          assembly {
            currentByte := byte(0, mload(add(add(currentVote, 0x20), j)))
          }

          // Next byte if this one is empty
          if (currentByte == 0) continue;

          // Extract 2 bits for each of the 4 validators in this byte,
          // and increment vote count for the given slash amount
          // Extract validator 0 vote: bits 0-1 (mask with 0x03 = 0b00000011)
          uint8 validatorSlash0 = currentByte & 0x03;
          if (validatorSlash0 != 0) {
            // Increment vote count at position (slashAmount-1) * 64 bits in packed uint256
            // Layout: [0-63: votes for 1 unit][64-127: votes for 2 units][128-191: votes for 3 units]
            tallyMatrix[baseIndex] += uint256(1) << ((validatorSlash0 - 1) << 6);
          }

          // Extract validator 1 vote: bits 2-3 (shift right 2, then mask with 0x03)
          uint8 validatorSlash1 = (currentByte >> 2) & 0x03;
          if (validatorSlash1 != 0) {
            tallyMatrix[baseIndex + 1] += uint256(1) << ((validatorSlash1 - 1) << 6);
          }

          // Extract validator 2 vote: bits 4-5 (shift right 4, then mask with 0x03)
          uint8 validatorSlash2 = (currentByte >> 4) & 0x03;
          if (validatorSlash2 != 0) {
            tallyMatrix[baseIndex + 2] += uint256(1) << ((validatorSlash2 - 1) << 6);
          }

          // Extract validator 3 vote: bits 6-7 (shift right 6, no mask needed as top 2 bits)
          uint8 validatorSlash3 = currentByte >> 6;
          if (validatorSlash3 != 0) {
            tallyMatrix[baseIndex + 3] += uint256(1) << ((validatorSlash3 - 1) << 6);
          }
        }
      }
    }
  }

  /**
   * @notice Determine which validators reached quorum and should be slashed
   */
  function _determineSlashActions(
    uint256[] memory tallyMatrix,
    address[][] calldata _committees,
    uint256 totalValidators
  ) internal view returns (SlashAction[] memory actions, bool[] memory committeesWithSlashes) {
    actions = new SlashAction[](totalValidators);
    uint256 actionCount;
    committeesWithSlashes = new bool[](ROUND_SIZE_IN_EPOCHS);

    unchecked {
      for (uint256 i; i < totalValidators; ++i) {
        uint256 packedVotes = tallyMatrix[i];

        // Skip if no votes for this validator
        if (packedVotes == 0) continue;

        uint256 voteCountForValidator;

        // Check slash amounts from highest (3 units) to lowest (1 unit)
        // Cumulative voting: votes for N units also count for N-1, N-2, etc.
        for (uint256 j = 3; j > 0;) {
          // Extract vote count for this slash amount from packed data
          // Shift right by (slashAmount-1) * 64 bits, then mask to get 64-bit segment
          // Layout: [0-63: votes for 1 unit][64-127: votes for 2 units][128-191: votes for 3 units]
          uint256 votesForAmount = (packedVotes >> ((j - 1) << 6)) & 0xFFFFFFFFFFFFFFFF;
          voteCountForValidator += votesForAmount;

          // Check if this slash amount has reached quorum
          if (voteCountForValidator >= QUORUM) {
            // Convert units to actual slash amount
            uint256 slashAmount;
            if (j == 1) {
              slashAmount = SLASH_AMOUNT_SMALL;
            } else if (j == 2) {
              slashAmount = SLASH_AMOUNT_MEDIUM;
            } else if (j == 3) {
              slashAmount = SLASH_AMOUNT_LARGE;
            }

            // Record the slashing action
            actions[actionCount] =
              SlashAction({validator: _committees[i / COMMITTEE_SIZE][i % COMMITTEE_SIZE], slashAmount: slashAmount});
            ++actionCount;

            // Mark this committee as having at least one slashed validator
            committeesWithSlashes[i / COMMITTEE_SIZE] = true;

            // Only slash each validator once at the highest amount that reached quorum
            break;
          }

          --j;
        }
      }
    }

    // Resize actions array to the actual number of actions using assembly
    assembly {
      mstore(actions, actionCount)
    }

    return (actions, committeesWithSlashes);
  }

  /**
   * @notice Load vote data from fixed-size format (optimized with unrolled loop)
   * @param voteSlots The storage reference to the vote slots
   * @param expectedLength The expected length of the vote data
   * @return voteData The reconstructed vote data as bytes
   */
  function _loadVoteDataFromStorage(bytes32[4] storage voteSlots, uint256 expectedLength)
    internal
    view
    returns (bytes memory voteData)
  {
    // Allocate memory for full chunks
    // This avoids complex masking by over-allocating slightly
    voteData = new bytes(4 * 32);

    unchecked {
      // Load full chunks without masking
      assembly {
        let dataPtr := add(voteData, 0x20)

        // Chunk 0 (bytes 0-31)
        if expectedLength {
          let chunk := sload(voteSlots.slot)
          mstore(dataPtr, chunk)
        }

        // Chunk 1 (bytes 32-63)
        if gt(expectedLength, 32) {
          let chunk := sload(add(voteSlots.slot, 1))
          mstore(add(dataPtr, 32), chunk)
        }

        // Chunk 2 (bytes 64-95)
        if gt(expectedLength, 64) {
          let chunk := sload(add(voteSlots.slot, 2))
          mstore(add(dataPtr, 64), chunk)
        }

        // Chunk 3 (bytes 96-127)
        if gt(expectedLength, 96) {
          let chunk := sload(add(voteSlots.slot, 3))
          mstore(add(dataPtr, 96), chunk)
        }

        // Adjust the array length to the expected length
        // This ensures the bytes array reports the correct length
        // even though we allocated extra memory
        mstore(voteData, expectedLength)
      }
    }
  }

  /**
   * @notice Get the current slot number from the rollup contract
   * @dev Retrieves the current time-based slot number which determines the active round and proposer.
   * @return The current Slot number
   */
  function _getCurrentSlot() internal view returns (Slot) {
    IValidatorSelection rollup = IValidatorSelection(INSTANCE);
    return rollup.getCurrentSlot();
  }

  /**
   * @notice Check if a round is ready for execution based on timing constraints
   * @dev A round is ready for execution when:
   *      1. Enough time has passed (current round > round + execution delay)
   *      2. Not too much time has passed (current round <= round + lifetime)
   *      This ensures there's time for review before execution while preventing stale executions.
   *
   * @param _round The round number to check readiness for
   * @param _currentRound The current round number for comparison
   * @return True if the round is ready for execution, false otherwise
   */
  function _isRoundReadyToExecute(SlashRound _round, SlashRound _currentRound) internal view returns (bool) {
    // Round must have passed execution delay but not exceeded lifetime
    // This gives time for review before execution and prevents stale executions
    return SlashRound.unwrap(_currentRound) > SlashRound.unwrap(_round) + EXECUTION_DELAY_IN_ROUNDS
      && SlashRound.unwrap(_currentRound) <= SlashRound.unwrap(_round) + LIFETIME_IN_ROUNDS;
  }

  /**
   * @notice Internal function to prepare payload data and compute address from slash actions
   * @param _round The round number (mixed into the salt)
   * @param _actions Array of slash actions
   * @return validators Array of validator addresses
   * @return amounts Array of slash amounts as uint96
   * @return salt The computed salt for CREATE2 deployment
   * @return predictedAddress The predicted address where the payload would be deployed
   */
  function _preparePayloadDataAndAddress(SlashRound _round, SlashAction[] memory _actions)
    internal
    view
    returns (address[] memory validators, uint96[] memory amounts, bytes32 salt, address predictedAddress)
  {
    uint256 actionCount = _actions.length;
    validators = new address[](actionCount);
    amounts = new uint96[](actionCount);

    // Extract validators and amounts from actions
    unchecked {
      for (uint256 i; i < actionCount; ++i) {
        validators[i] = _actions[i].validator;
        // Convert uint256 to uint96, checking for overflow
        require(_actions[i].slashAmount <= type(uint96).max, Errors.TallySlashingProposer__SlashAmountTooLarge());
        amounts[i] = uint96(_actions[i].slashAmount);
      }
    }

    // Compute salt for CREATE2 deployment, including round number
    salt = keccak256(abi.encodePacked(SlashRound.unwrap(_round), validators, amounts));

    // Compute predicted address using clone deterministic address prediction
    bytes memory immutableArgs = SlashPayloadLib.encodeImmutableArgs(INSTANCE, validators, amounts);
    predictedAddress = Clones.predictDeterministicAddressWithImmutableArgs(
      SLASH_PAYLOAD_IMPLEMENTATION, immutableArgs, salt, address(this)
    );

    return (validators, amounts, salt, predictedAddress);
  }

  /**
   * @notice Returns a storage reference to the round votes for a specific round from the circular storage buffer
   * @dev Uses modulo arithmetic to map round numbers to storage slots in the circular buffer.
   *      IMPORTANT: This function DOES NOT validate that the round is within the valid range or that
   *      the data hasn't been overwritten by newer rounds. Always call getRoundData() first to ensure
   *      the round data is valid before using this function.
   *
   * @param _round The round number to get votes for
   * @return A storage reference to the RoundVotes struct containing the vote data for this round
   */
  function _getRoundVotes(SlashRound _round) internal view returns (RoundVotes storage) {
    // Map round number to circular storage index using modulo
    // This allows reuse of storage slots as older rounds become irrelevant
    return roundVotes[SlashRound.unwrap(_round) % ROUNDABOUT_SIZE];
  }

  /**
   * @notice Get round data for a specific round, loading from circular storage and decompressing it
   * @param _round The round number to retrieve data for
   * @param _currentRound The current round number, so we dont try loading data outside the valid roundabout range.
   * Required as a parameter to avoid having to recompute it on every call to this function.
   * @return RoundData struct containing the round's data
   */
  function _getRoundData(SlashRound _round, SlashRound _currentRound) internal view returns (RoundData memory) {
    // Check if the requested round is within the valid roundabout range
    if (
      SlashRound.unwrap(_round) > SlashRound.unwrap(_currentRound)
        || SlashRound.unwrap(_round) + ROUNDABOUT_SIZE <= SlashRound.unwrap(_currentRound)
    ) {
      revert Errors.TallySlashingProposer__RoundOutOfRange((_round), (_currentRound));
    }

    // Load round data from the circular storage into memory in a single SLOAD
    CompressedRoundData memory roundData = roundDatas[SlashRound.unwrap(_round) % ROUNDABOUT_SIZE];

    // If we find in storage round data for an older round since we've gone around the roundabout, return an empty one
    if (roundData.roundNumber.decompress() != _round) {
      return RoundData({roundNumber: _round, lastVoteSlot: Slot.wrap(0), voteCount: 0, executed: false});
    }

    return RoundData({
      roundNumber: _round,
      lastVoteSlot: roundData.lastVoteSlot.decompress(),
      voteCount: roundData.voteCount,
      executed: roundData.executed
    });
  }

  /**
   * @notice Computes the round at the given slot
   * @param _slot - The slot to compute round for
   * @return The round number
   */
  function _computeRound(Slot _slot) internal view returns (SlashRound) {
    return SlashRound.wrap(Slot.unwrap(_slot) / ROUND_SIZE);
  }

  /**
   * @notice Process 32 bytes of vote data at once
   * @dev Processes a full word for maximum efficiency with early exit for zero words
   */
  function _process32BytesVotes(uint256[] memory tallyMatrix, bytes memory currentVote, uint256 startJ) internal pure {
    unchecked {
      // Load 32 bytes as a single word
      uint256 word;
      assembly {
        word := mload(add(add(currentVote, 0x20), startJ))
      }

      // Early exit if entire word is zero (no votes)
      if (word == 0) return;

      // Process the 32-byte word byte by byte, maintaining big-endian order
      uint256 baseIndex = startJ << 2; // Convert byte index to validator index: startJ * 4

      for (uint256 i; i < 32; ++i) {
        // Early exit if remaining word is zero
        if (word == 0) break;

        // Extract most significant byte from word (big-endian order)
        // Shift right 248 bits (31 bytes) to get the leftmost byte
        uint8 currentByte = uint8(word >> 248);

        // Shift word left by 8 bits for next iteration, removing processed byte
        word <<= 8;

        if (currentByte != 0) {
          uint256 idx = baseIndex + (i << 2); // Convert byte index to validator index: baseIndex + i * 4

          // Extract validator 0 vote: bits 0-1 (mask with 0x03 = 0b00000011)
          uint8 v0 = currentByte & 0x03;
          if (v0 != 0) tallyMatrix[idx] += uint256(1) << ((v0 - 1) << 6);

          // Extract validator 1 vote: bits 2-3 (shift right 2, then mask with 0x03)
          uint8 v1 = (currentByte >> 2) & 0x03;
          if (v1 != 0) tallyMatrix[idx + 1] += uint256(1) << ((v1 - 1) << 6);

          // Extract validator 2 vote: bits 4-5 (shift right 4, then mask with 0x03)
          uint8 v2 = (currentByte >> 4) & 0x03;
          if (v2 != 0) tallyMatrix[idx + 2] += uint256(1) << ((v2 - 1) << 6);

          // Extract validator 3 vote: bits 6-7 (shift right 6, no mask needed)
          uint8 v3 = currentByte >> 6;
          if (v3 != 0) tallyMatrix[idx + 3] += uint256(1) << ((v3 - 1) << 6);
        }
      }
    }
  }

  /**
   * @notice Reconstruct committee commitment from addresses
   */
  function _computeCommitteeCommitment(address[] calldata _committee) internal pure returns (bytes32) {
    // Hash the committee addresses to create a commitment for verification
    // Duplicated from ValidatorSelectionLib.sol
    return keccak256(abi.encode(_committee));
  }
}


// File: lib/l1-contracts/src/core/slashing/EmpireSlashingProposer.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {ISlasher, SlasherFlavor} from "@aztec/core/interfaces/ISlasher.sol";
import {IEmpire} from "@aztec/governance/interfaces/IEmpire.sol";
import {IPayload} from "@aztec/governance/interfaces/IPayload.sol";
import {EmpireBase} from "@aztec/governance/proposer/EmpireBase.sol";

/**
 * @notice  A SlashingProposer implementation following the empire model
 */
contract EmpireSlashingProposer is IEmpire, EmpireBase {
  /**
   * @notice Type of slashing proposer (either Tally or Empire)
   */
  SlasherFlavor public constant SLASHING_PROPOSER_TYPE = SlasherFlavor.EMPIRE;

  address public immutable INSTANCE;
  ISlasher public immutable SLASHER;

  /**
   * @notice Constructor for the EmpireSlashingProposer contract.
   *
   * @param _instance - The specific rollup that the proposer will be used for
   * @param _slasher - The entity that can slash on the _instance
   *                    The EmpireSlashingProposer `address(this)` should be able to use the slasher for this contract
   * to
   *                    make sense.
   * @param _slashingQuorum The number of signals needed in a round for a slash to pass.
   * @param _roundSize The number of signals that can be cast in a round.
   * @param _lifetimeInRounds - A deadline for when the passing proposal must have been executed.
   * @param _executionDelayInRounds - A delay for how quickly a passing proposal can be executed.
   *                                  When used together with a `_slasher` that has VETO functionality this is the time
   *                                  that the vetoer have to act.
   */
  constructor(
    address _instance,
    ISlasher _slasher,
    uint256 _slashingQuorum,
    uint256 _roundSize,
    uint256 _lifetimeInRounds,
    uint256 _executionDelayInRounds
  ) EmpireBase(_slashingQuorum, _roundSize, _lifetimeInRounds, _executionDelayInRounds) {
    INSTANCE = _instance;
    SLASHER = _slasher;
  }

  function getInstance() public view override(EmpireBase, IEmpire) returns (address) {
    return INSTANCE;
  }

  function _handleRoundWinner(IPayload _payload) internal override(EmpireBase) returns (bool) {
    return SLASHER.slash(_payload);
  }
}


// File: lib/l1-contracts/src/core/libraries/crypto/FrontierLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {Hash} from "@aztec/core/libraries/crypto/Hash.sol";

/**
 * @title FrontierLib
 * @author Aztec Labs
 * @notice Library for managing frontier trees.
 */
library FrontierLib {
  struct Forest {
    mapping(uint256 index => bytes32 zero) zeros;
  }

  struct Tree {
    uint256 nextIndex;
    mapping(uint256 => bytes32) frontier;
  }

  function initialize(Forest storage _self, uint256 _height) internal {
    _self.zeros[0] = bytes32(0);
    for (uint256 i = 1; i <= _height; i++) {
      _self.zeros[i] = Hash.sha256ToField(bytes.concat(_self.zeros[i - 1], _self.zeros[i - 1]));
    }
  }

  function insertLeaf(Tree storage _self, bytes32 _leaf) internal returns (uint256) {
    uint256 index = _self.nextIndex;
    uint256 level = computeLevel(index);
    bytes32 right = _leaf;
    for (uint256 i = 0; i < level; i++) {
      right = Hash.sha256ToField(bytes.concat(_self.frontier[i], right));
    }
    _self.frontier[level] = right;

    _self.nextIndex++;

    return index;
  }

  function root(Tree storage _self, Forest storage _forest, uint256 _height, uint256 _size)
    internal
    view
    returns (bytes32)
  {
    uint256 next = _self.nextIndex;
    if (next == 0) {
      return _forest.zeros[_height];
    }
    if (next == _size) {
      return _self.frontier[_height];
    }

    uint256 index = next - 1;
    uint256 level = computeLevel(index);

    // We should start at the highest frontier level with a left leaf
    bytes32 temp = _self.frontier[level];

    uint256 bits = index >> level;
    for (uint256 i = level; i < _height; i++) {
      bool isRight = bits & 1 == 1;
      if (isRight) {
        temp = Hash.sha256ToField(bytes.concat(_self.frontier[i], temp));
      } else {
        temp = Hash.sha256ToField(bytes.concat(temp, _forest.zeros[i]));
      }
      bits >>= 1;
    }

    return temp;
  }

  function isFull(Tree storage _self, uint256 _size) internal view returns (bool) {
    return _self.nextIndex == _size;
  }

  function computeLevel(uint256 _leafIndex) internal pure returns (uint256) {
    // The number of trailing ones is how many times in a row we are the right child.
    // e.g., each time this happens we go another layer up to update the parent.
    uint256 count = 0;
    uint256 index = _leafIndex;
    while (index & 1 == 1) {
      count++;
      index >>= 1;
    }
    return count;
  }
}


// File: lib/l1-contracts/src/core/messagebridge/FeeJuicePortal.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {IFeeJuicePortal} from "@aztec/core/interfaces/IFeeJuicePortal.sol";
import {IRollup} from "@aztec/core/interfaces/IRollup.sol";
import {IInbox} from "@aztec/core/interfaces/messagebridge/IInbox.sol";
import {Constants} from "@aztec/core/libraries/ConstantsGen.sol";
import {Hash} from "@aztec/core/libraries/crypto/Hash.sol";
import {DataStructures} from "@aztec/core/libraries/DataStructures.sol";
import {Errors} from "@aztec/core/libraries/Errors.sol";
import {IERC20} from "@oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "@oz/token/ERC20/utils/SafeERC20.sol";

contract FeeJuicePortal is IFeeJuicePortal {
  using SafeERC20 for IERC20;

  bytes32 public constant L2_TOKEN_ADDRESS = bytes32(Constants.FEE_JUICE_ADDRESS);

  IRollup public immutable ROLLUP;
  IInbox public immutable INBOX;
  IERC20 public immutable UNDERLYING;
  uint256 public immutable VERSION;

  constructor(IRollup _rollup, IERC20 _underlying, IInbox _inbox, uint256 _version) {
    ROLLUP = _rollup;
    INBOX = _inbox;
    UNDERLYING = _underlying;
    VERSION = _version;
  }

  /**
   * @notice Deposit funds into the portal and adds an L2 message which can only be consumed publicly on Aztec
   * @param _to - The aztec address of the recipient
   * @param _amount - The amount to deposit
   * @param _secretHash - The hash of the secret consumable message. The hash should be 254 bits (so it can fit in a
   * Field element)
   * @return - The key of the entry in the Inbox and its leaf index
   */
  function depositToAztecPublic(bytes32 _to, uint256 _amount, bytes32 _secretHash)
    external
    override(IFeeJuicePortal)
    returns (bytes32, uint256)
  {
    // Preamble
    DataStructures.L2Actor memory actor = DataStructures.L2Actor(L2_TOKEN_ADDRESS, VERSION);

    // Hash the message content to be reconstructed in the receiving contract
    bytes32 contentHash = Hash.sha256ToField(abi.encodeWithSignature("claim(bytes32,uint256)", _to, _amount));

    // Hold the tokens in the portal
    UNDERLYING.safeTransferFrom(msg.sender, address(this), _amount);

    // Send message to rollup
    (bytes32 key, uint256 index) = INBOX.sendL2Message(actor, contentHash, _secretHash);

    emit DepositToAztecPublic(_to, _amount, _secretHash, key, index);

    return (key, index);
  }

  /**
   * @notice  Let the rollup distribute fees to an account
   *
   *          Since the assets cannot be exited the usual way, but only paid as fees to sequencers
   *          we include this function to allow the rollup to do just that, bypassing the usual
   *          flows.
   *
   * @param _to - The address to receive the payment
   * @param _amount - The amount to pay them
   */
  function distributeFees(address _to, uint256 _amount) external override(IFeeJuicePortal) {
    require(msg.sender == address(ROLLUP), Errors.FeeJuicePortal__Unauthorized());
    UNDERLYING.safeTransfer(_to, _amount);

    emit FeesDistributed(_to, _amount);
  }
}


// File: lib/l1-contracts/src/core/libraries/crypto/MerkleLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {Hash} from "@aztec/core/libraries/crypto/Hash.sol";
import {Errors} from "@aztec/core/libraries/Errors.sol";

/**
 * @title Merkle Library
 * @author Aztec Labs
 * @notice Library that contains functions useful when interacting with Merkle Trees
 */
library MerkleLib {
  /**
   * @notice Verifies the membership of a leaf and path against an expected root.
   * @dev In the case of a mismatched root, and subsequent inability to verify membership, this function throws.
   * @param _path - The sibling path of the message as a leaf, used to prove message inclusion
   * @param _leaf - The hash of the message we are trying to prove inclusion for
   * @param _index - The index of the message inside the L2 to L1 message tree
   * @param _expectedRoot - The expected root to check the validity of the message and sibling path with.
   * @notice -
   * E.g. A sibling path for a leaf at index 3 (L) in a tree of depth 3 (between 5 and 8 leafs) consists of the 3
   * elements denoted as *'s
   * d0:                                            [ root ]
   * d1:                      [ ]                                               [*]
   * d2:         [*]                      [ ]                       [ ]                     [ ]
   * d3:   [ ]         [ ]          [*]         [L]           [ ]         [ ]          [ ]        [ ].
   * And the elements would be ordered as: [ d3_index_2, d2_index_0, d1_index_1 ].
   */
  function verifyMembership(bytes32[] calldata _path, bytes32 _leaf, uint256 _index, bytes32 _expectedRoot)
    internal
    pure
  {
    bytes32 subtreeRoot = _leaf;
    /// @notice - We use the indexAtHeight to see whether our child of the next subtree is at the left or the right side
    uint256 indexAtHeight = _index;

    for (uint256 height = 0; height < _path.length; height++) {
      /// @notice - This affects the way we concatenate our two children to then hash and calculate the root, as any odd
      /// indexes (index bit-masked with least significant bit) are right-sided children.
      bool isRight = (indexAtHeight & 1) == 1;

      subtreeRoot = isRight
        ? Hash.sha256ToField(bytes.concat(_path[height], subtreeRoot))
        : Hash.sha256ToField(bytes.concat(subtreeRoot, _path[height]));
      /// @notice - We divide by two here to get the index of the parent of the current subtreeRoot in its own layer
      indexAtHeight >>= 1;
    }

    // Security: Ensure the index doesn't have bits set beyond the tree height
    // This prevents replay attacks where an attacker could use index 8 with path length 2 to walk the same path as
    // index 0.
    require(indexAtHeight == 0, Errors.MerkleLib__InvalidIndexForPathLength());
    require(subtreeRoot == _expectedRoot, Errors.MerkleLib__InvalidRoot(_expectedRoot, subtreeRoot, _leaf, _index));
  }
}


// File: lib/openzeppelin-contracts/contracts/utils/ShortStrings.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.3.0) (utils/ShortStrings.sol)

pragma solidity ^0.8.20;

import {StorageSlot} from "./StorageSlot.sol";

// | string  | 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA   |
// | length  | 0x                                                              BB |
type ShortString is bytes32;

/**
 * @dev This library provides functions to convert short memory strings
 * into a `ShortString` type that can be used as an immutable variable.
 *
 * Strings of arbitrary length can be optimized using this library if
 * they are short enough (up to 31 bytes) by packing them with their
 * length (1 byte) in a single EVM word (32 bytes). Additionally, a
 * fallback mechanism can be used for every other case.
 *
 * Usage example:
 *
 * ```solidity
 * contract Named {
 *     using ShortStrings for *;
 *
 *     ShortString private immutable _name;
 *     string private _nameFallback;
 *
 *     constructor(string memory contractName) {
 *         _name = contractName.toShortStringWithFallback(_nameFallback);
 *     }
 *
 *     function name() external view returns (string memory) {
 *         return _name.toStringWithFallback(_nameFallback);
 *     }
 * }
 * ```
 */
library ShortStrings {
    // Used as an identifier for strings longer than 31 bytes.
    bytes32 private constant FALLBACK_SENTINEL = 0x00000000000000000000000000000000000000000000000000000000000000FF;

    error StringTooLong(string str);
    error InvalidShortString();

    /**
     * @dev Encode a string of at most 31 chars into a `ShortString`.
     *
     * This will trigger a `StringTooLong` error is the input string is too long.
     */
    function toShortString(string memory str) internal pure returns (ShortString) {
        bytes memory bstr = bytes(str);
        if (bstr.length > 31) {
            revert StringTooLong(str);
        }
        return ShortString.wrap(bytes32(uint256(bytes32(bstr)) | bstr.length));
    }

    /**
     * @dev Decode a `ShortString` back to a "normal" string.
     */
    function toString(ShortString sstr) internal pure returns (string memory) {
        uint256 len = byteLength(sstr);
        // using `new string(len)` would work locally but is not memory safe.
        string memory str = new string(32);
        assembly ("memory-safe") {
            mstore(str, len)
            mstore(add(str, 0x20), sstr)
        }
        return str;
    }

    /**
     * @dev Return the length of a `ShortString`.
     */
    function byteLength(ShortString sstr) internal pure returns (uint256) {
        uint256 result = uint256(ShortString.unwrap(sstr)) & 0xFF;
        if (result > 31) {
            revert InvalidShortString();
        }
        return result;
    }

    /**
     * @dev Encode a string into a `ShortString`, or write it to storage if it is too long.
     */
    function toShortStringWithFallback(string memory value, string storage store) internal returns (ShortString) {
        if (bytes(value).length < 32) {
            return toShortString(value);
        } else {
            StorageSlot.getStringSlot(store).value = value;
            return ShortString.wrap(FALLBACK_SENTINEL);
        }
    }

    /**
     * @dev Decode a string that was encoded to `ShortString` or written to storage using {toShortStringWithFallback}.
     */
    function toStringWithFallback(ShortString value, string storage store) internal pure returns (string memory) {
        if (ShortString.unwrap(value) != FALLBACK_SENTINEL) {
            return toString(value);
        } else {
            return store;
        }
    }

    /**
     * @dev Return the length of a string that was encoded to `ShortString` or written to storage using
     * {toShortStringWithFallback}.
     *
     * WARNING: This will return the "byte length" of the string. This may not reflect the actual length in terms of
     * actual characters as the UTF-8 encoding of a single character can span over multiple bytes.
     */
    function byteLengthWithFallback(ShortString value, string storage store) internal view returns (uint256) {
        if (ShortString.unwrap(value) != FALLBACK_SENTINEL) {
            return byteLength(value);
        } else {
            return bytes(store).length;
        }
    }
}


// File: lib/openzeppelin-contracts/contracts/interfaces/IERC5267.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/IERC5267.sol)

pragma solidity ^0.8.20;

interface IERC5267 {
    /**
     * @dev MAY be emitted to signal that the domain could have changed.
     */
    event EIP712DomainChanged();

    /**
     * @dev returns the fields and values that describe the domain separator used by this contract for EIP-712
     * signature.
     */
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        );
}


// File: lib/l1-contracts/src/governance/interfaces/IProposerPayload.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {IPayload} from "@aztec/governance/interfaces/IPayload.sol";

interface IProposerPayload is IPayload {
  function getOriginalPayload() external view returns (IPayload);

  function amIValid() external view returns (bool);
}


// File: lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/IERC20.sol)

pragma solidity ^0.8.20;

import {IERC20} from "../token/ERC20/IERC20.sol";


// File: lib/openzeppelin-contracts/contracts/interfaces/IERC165.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/IERC165.sol)

pragma solidity ^0.8.20;

import {IERC165} from "../utils/introspection/IERC165.sol";


// File: lib/openzeppelin-contracts/contracts/utils/Strings.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.3.0) (utils/Strings.sol)

pragma solidity ^0.8.20;

import {Math} from "./math/Math.sol";
import {SafeCast} from "./math/SafeCast.sol";
import {SignedMath} from "./math/SignedMath.sol";

/**
 * @dev String operations.
 */
library Strings {
    using SafeCast for *;

    bytes16 private constant HEX_DIGITS = "0123456789abcdef";
    uint8 private constant ADDRESS_LENGTH = 20;
    uint256 private constant SPECIAL_CHARS_LOOKUP =
        (1 << 0x08) | // backspace
            (1 << 0x09) | // tab
            (1 << 0x0a) | // newline
            (1 << 0x0c) | // form feed
            (1 << 0x0d) | // carriage return
            (1 << 0x22) | // double quote
            (1 << 0x5c); // backslash

    /**
     * @dev The `value` string doesn't fit in the specified `length`.
     */
    error StringsInsufficientHexLength(uint256 value, uint256 length);

    /**
     * @dev The string being parsed contains characters that are not in scope of the given base.
     */
    error StringsInvalidChar();

    /**
     * @dev The string being parsed is not a properly formatted address.
     */
    error StringsInvalidAddressFormat();

    /**
     * @dev Converts a `uint256` to its ASCII `string` decimal representation.
     */
    function toString(uint256 value) internal pure returns (string memory) {
        unchecked {
            uint256 length = Math.log10(value) + 1;
            string memory buffer = new string(length);
            uint256 ptr;
            assembly ("memory-safe") {
                ptr := add(buffer, add(32, length))
            }
            while (true) {
                ptr--;
                assembly ("memory-safe") {
                    mstore8(ptr, byte(mod(value, 10), HEX_DIGITS))
                }
                value /= 10;
                if (value == 0) break;
            }
            return buffer;
        }
    }

    /**
     * @dev Converts a `int256` to its ASCII `string` decimal representation.
     */
    function toStringSigned(int256 value) internal pure returns (string memory) {
        return string.concat(value < 0 ? "-" : "", toString(SignedMath.abs(value)));
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation.
     */
    function toHexString(uint256 value) internal pure returns (string memory) {
        unchecked {
            return toHexString(value, Math.log256(value) + 1);
        }
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation with fixed length.
     */
    function toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        uint256 localValue = value;
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = HEX_DIGITS[localValue & 0xf];
            localValue >>= 4;
        }
        if (localValue != 0) {
            revert StringsInsufficientHexLength(value, length);
        }
        return string(buffer);
    }

    /**
     * @dev Converts an `address` with fixed length of 20 bytes to its not checksummed ASCII `string` hexadecimal
     * representation.
     */
    function toHexString(address addr) internal pure returns (string memory) {
        return toHexString(uint256(uint160(addr)), ADDRESS_LENGTH);
    }

    /**
     * @dev Converts an `address` with fixed length of 20 bytes to its checksummed ASCII `string` hexadecimal
     * representation, according to EIP-55.
     */
    function toChecksumHexString(address addr) internal pure returns (string memory) {
        bytes memory buffer = bytes(toHexString(addr));

        // hash the hex part of buffer (skip length + 2 bytes, length 40)
        uint256 hashValue;
        assembly ("memory-safe") {
            hashValue := shr(96, keccak256(add(buffer, 0x22), 40))
        }

        for (uint256 i = 41; i > 1; --i) {
            // possible values for buffer[i] are 48 (0) to 57 (9) and 97 (a) to 102 (f)
            if (hashValue & 0xf > 7 && uint8(buffer[i]) > 96) {
                // case shift by xoring with 0x20
                buffer[i] ^= 0x20;
            }
            hashValue >>= 4;
        }
        return string(buffer);
    }

    /**
     * @dev Returns true if the two strings are equal.
     */
    function equal(string memory a, string memory b) internal pure returns (bool) {
        return bytes(a).length == bytes(b).length && keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /**
     * @dev Parse a decimal string and returns the value as a `uint256`.
     *
     * Requirements:
     * - The string must be formatted as `[0-9]*`
     * - The result must fit into an `uint256` type
     */
    function parseUint(string memory input) internal pure returns (uint256) {
        return parseUint(input, 0, bytes(input).length);
    }

    /**
     * @dev Variant of {parseUint-string} that parses a substring of `input` located between position `begin` (included) and
     * `end` (excluded).
     *
     * Requirements:
     * - The substring must be formatted as `[0-9]*`
     * - The result must fit into an `uint256` type
     */
    function parseUint(string memory input, uint256 begin, uint256 end) internal pure returns (uint256) {
        (bool success, uint256 value) = tryParseUint(input, begin, end);
        if (!success) revert StringsInvalidChar();
        return value;
    }

    /**
     * @dev Variant of {parseUint-string} that returns false if the parsing fails because of an invalid character.
     *
     * NOTE: This function will revert if the result does not fit in a `uint256`.
     */
    function tryParseUint(string memory input) internal pure returns (bool success, uint256 value) {
        return _tryParseUintUncheckedBounds(input, 0, bytes(input).length);
    }

    /**
     * @dev Variant of {parseUint-string-uint256-uint256} that returns false if the parsing fails because of an invalid
     * character.
     *
     * NOTE: This function will revert if the result does not fit in a `uint256`.
     */
    function tryParseUint(
        string memory input,
        uint256 begin,
        uint256 end
    ) internal pure returns (bool success, uint256 value) {
        if (end > bytes(input).length || begin > end) return (false, 0);
        return _tryParseUintUncheckedBounds(input, begin, end);
    }

    /**
     * @dev Implementation of {tryParseUint-string-uint256-uint256} that does not check bounds. Caller should make sure that
     * `begin <= end <= input.length`. Other inputs would result in undefined behavior.
     */
    function _tryParseUintUncheckedBounds(
        string memory input,
        uint256 begin,
        uint256 end
    ) private pure returns (bool success, uint256 value) {
        bytes memory buffer = bytes(input);

        uint256 result = 0;
        for (uint256 i = begin; i < end; ++i) {
            uint8 chr = _tryParseChr(bytes1(_unsafeReadBytesOffset(buffer, i)));
            if (chr > 9) return (false, 0);
            result *= 10;
            result += chr;
        }
        return (true, result);
    }

    /**
     * @dev Parse a decimal string and returns the value as a `int256`.
     *
     * Requirements:
     * - The string must be formatted as `[-+]?[0-9]*`
     * - The result must fit in an `int256` type.
     */
    function parseInt(string memory input) internal pure returns (int256) {
        return parseInt(input, 0, bytes(input).length);
    }

    /**
     * @dev Variant of {parseInt-string} that parses a substring of `input` located between position `begin` (included) and
     * `end` (excluded).
     *
     * Requirements:
     * - The substring must be formatted as `[-+]?[0-9]*`
     * - The result must fit in an `int256` type.
     */
    function parseInt(string memory input, uint256 begin, uint256 end) internal pure returns (int256) {
        (bool success, int256 value) = tryParseInt(input, begin, end);
        if (!success) revert StringsInvalidChar();
        return value;
    }

    /**
     * @dev Variant of {parseInt-string} that returns false if the parsing fails because of an invalid character or if
     * the result does not fit in a `int256`.
     *
     * NOTE: This function will revert if the absolute value of the result does not fit in a `uint256`.
     */
    function tryParseInt(string memory input) internal pure returns (bool success, int256 value) {
        return _tryParseIntUncheckedBounds(input, 0, bytes(input).length);
    }

    uint256 private constant ABS_MIN_INT256 = 2 ** 255;

    /**
     * @dev Variant of {parseInt-string-uint256-uint256} that returns false if the parsing fails because of an invalid
     * character or if the result does not fit in a `int256`.
     *
     * NOTE: This function will revert if the absolute value of the result does not fit in a `uint256`.
     */
    function tryParseInt(
        string memory input,
        uint256 begin,
        uint256 end
    ) internal pure returns (bool success, int256 value) {
        if (end > bytes(input).length || begin > end) return (false, 0);
        return _tryParseIntUncheckedBounds(input, begin, end);
    }

    /**
     * @dev Implementation of {tryParseInt-string-uint256-uint256} that does not check bounds. Caller should make sure that
     * `begin <= end <= input.length`. Other inputs would result in undefined behavior.
     */
    function _tryParseIntUncheckedBounds(
        string memory input,
        uint256 begin,
        uint256 end
    ) private pure returns (bool success, int256 value) {
        bytes memory buffer = bytes(input);

        // Check presence of a negative sign.
        bytes1 sign = begin == end ? bytes1(0) : bytes1(_unsafeReadBytesOffset(buffer, begin)); // don't do out-of-bound (possibly unsafe) read if sub-string is empty
        bool positiveSign = sign == bytes1("+");
        bool negativeSign = sign == bytes1("-");
        uint256 offset = (positiveSign || negativeSign).toUint();

        (bool absSuccess, uint256 absValue) = tryParseUint(input, begin + offset, end);

        if (absSuccess && absValue < ABS_MIN_INT256) {
            return (true, negativeSign ? -int256(absValue) : int256(absValue));
        } else if (absSuccess && negativeSign && absValue == ABS_MIN_INT256) {
            return (true, type(int256).min);
        } else return (false, 0);
    }

    /**
     * @dev Parse a hexadecimal string (with or without "0x" prefix), and returns the value as a `uint256`.
     *
     * Requirements:
     * - The string must be formatted as `(0x)?[0-9a-fA-F]*`
     * - The result must fit in an `uint256` type.
     */
    function parseHexUint(string memory input) internal pure returns (uint256) {
        return parseHexUint(input, 0, bytes(input).length);
    }

    /**
     * @dev Variant of {parseHexUint-string} that parses a substring of `input` located between position `begin` (included) and
     * `end` (excluded).
     *
     * Requirements:
     * - The substring must be formatted as `(0x)?[0-9a-fA-F]*`
     * - The result must fit in an `uint256` type.
     */
    function parseHexUint(string memory input, uint256 begin, uint256 end) internal pure returns (uint256) {
        (bool success, uint256 value) = tryParseHexUint(input, begin, end);
        if (!success) revert StringsInvalidChar();
        return value;
    }

    /**
     * @dev Variant of {parseHexUint-string} that returns false if the parsing fails because of an invalid character.
     *
     * NOTE: This function will revert if the result does not fit in a `uint256`.
     */
    function tryParseHexUint(string memory input) internal pure returns (bool success, uint256 value) {
        return _tryParseHexUintUncheckedBounds(input, 0, bytes(input).length);
    }

    /**
     * @dev Variant of {parseHexUint-string-uint256-uint256} that returns false if the parsing fails because of an
     * invalid character.
     *
     * NOTE: This function will revert if the result does not fit in a `uint256`.
     */
    function tryParseHexUint(
        string memory input,
        uint256 begin,
        uint256 end
    ) internal pure returns (bool success, uint256 value) {
        if (end > bytes(input).length || begin > end) return (false, 0);
        return _tryParseHexUintUncheckedBounds(input, begin, end);
    }

    /**
     * @dev Implementation of {tryParseHexUint-string-uint256-uint256} that does not check bounds. Caller should make sure that
     * `begin <= end <= input.length`. Other inputs would result in undefined behavior.
     */
    function _tryParseHexUintUncheckedBounds(
        string memory input,
        uint256 begin,
        uint256 end
    ) private pure returns (bool success, uint256 value) {
        bytes memory buffer = bytes(input);

        // skip 0x prefix if present
        bool hasPrefix = (end > begin + 1) && bytes2(_unsafeReadBytesOffset(buffer, begin)) == bytes2("0x"); // don't do out-of-bound (possibly unsafe) read if sub-string is empty
        uint256 offset = hasPrefix.toUint() * 2;

        uint256 result = 0;
        for (uint256 i = begin + offset; i < end; ++i) {
            uint8 chr = _tryParseChr(bytes1(_unsafeReadBytesOffset(buffer, i)));
            if (chr > 15) return (false, 0);
            result *= 16;
            unchecked {
                // Multiplying by 16 is equivalent to a shift of 4 bits (with additional overflow check).
                // This guarantees that adding a value < 16 will not cause an overflow, hence the unchecked.
                result += chr;
            }
        }
        return (true, result);
    }

    /**
     * @dev Parse a hexadecimal string (with or without "0x" prefix), and returns the value as an `address`.
     *
     * Requirements:
     * - The string must be formatted as `(0x)?[0-9a-fA-F]{40}`
     */
    function parseAddress(string memory input) internal pure returns (address) {
        return parseAddress(input, 0, bytes(input).length);
    }

    /**
     * @dev Variant of {parseAddress-string} that parses a substring of `input` located between position `begin` (included) and
     * `end` (excluded).
     *
     * Requirements:
     * - The substring must be formatted as `(0x)?[0-9a-fA-F]{40}`
     */
    function parseAddress(string memory input, uint256 begin, uint256 end) internal pure returns (address) {
        (bool success, address value) = tryParseAddress(input, begin, end);
        if (!success) revert StringsInvalidAddressFormat();
        return value;
    }

    /**
     * @dev Variant of {parseAddress-string} that returns false if the parsing fails because the input is not a properly
     * formatted address. See {parseAddress-string} requirements.
     */
    function tryParseAddress(string memory input) internal pure returns (bool success, address value) {
        return tryParseAddress(input, 0, bytes(input).length);
    }

    /**
     * @dev Variant of {parseAddress-string-uint256-uint256} that returns false if the parsing fails because input is not a properly
     * formatted address. See {parseAddress-string-uint256-uint256} requirements.
     */
    function tryParseAddress(
        string memory input,
        uint256 begin,
        uint256 end
    ) internal pure returns (bool success, address value) {
        if (end > bytes(input).length || begin > end) return (false, address(0));

        bool hasPrefix = (end > begin + 1) && bytes2(_unsafeReadBytesOffset(bytes(input), begin)) == bytes2("0x"); // don't do out-of-bound (possibly unsafe) read if sub-string is empty
        uint256 expectedLength = 40 + hasPrefix.toUint() * 2;

        // check that input is the correct length
        if (end - begin == expectedLength) {
            // length guarantees that this does not overflow, and value is at most type(uint160).max
            (bool s, uint256 v) = _tryParseHexUintUncheckedBounds(input, begin, end);
            return (s, address(uint160(v)));
        } else {
            return (false, address(0));
        }
    }

    function _tryParseChr(bytes1 chr) private pure returns (uint8) {
        uint8 value = uint8(chr);

        // Try to parse `chr`:
        // - Case 1: [0-9]
        // - Case 2: [a-f]
        // - Case 3: [A-F]
        // - otherwise not supported
        unchecked {
            if (value > 47 && value < 58) value -= 48;
            else if (value > 96 && value < 103) value -= 87;
            else if (value > 64 && value < 71) value -= 55;
            else return type(uint8).max;
        }

        return value;
    }

    /**
     * @dev Escape special characters in JSON strings. This can be useful to prevent JSON injection in NFT metadata.
     *
     * WARNING: This function should only be used in double quoted JSON strings. Single quotes are not escaped.
     *
     * NOTE: This function escapes all unicode characters, and not just the ones in ranges defined in section 2.5 of
     * RFC-4627 (U+0000 to U+001F, U+0022 and U+005C). ECMAScript's `JSON.parse` does recover escaped unicode
     * characters that are not in this range, but other tooling may provide different results.
     */
    function escapeJSON(string memory input) internal pure returns (string memory) {
        bytes memory buffer = bytes(input);
        bytes memory output = new bytes(2 * buffer.length); // worst case scenario
        uint256 outputLength = 0;

        for (uint256 i; i < buffer.length; ++i) {
            bytes1 char = bytes1(_unsafeReadBytesOffset(buffer, i));
            if (((SPECIAL_CHARS_LOOKUP & (1 << uint8(char))) != 0)) {
                output[outputLength++] = "\\";
                if (char == 0x08) output[outputLength++] = "b";
                else if (char == 0x09) output[outputLength++] = "t";
                else if (char == 0x0a) output[outputLength++] = "n";
                else if (char == 0x0c) output[outputLength++] = "f";
                else if (char == 0x0d) output[outputLength++] = "r";
                else if (char == 0x5c) output[outputLength++] = "\\";
                else if (char == 0x22) {
                    // solhint-disable-next-line quotes
                    output[outputLength++] = '"';
                }
            } else {
                output[outputLength++] = char;
            }
        }
        // write the actual length and deallocate unused memory
        assembly ("memory-safe") {
            mstore(output, outputLength)
            mstore(0x40, add(output, shl(5, shr(5, add(outputLength, 63)))))
        }

        return string(output);
    }

    /**
     * @dev Reads a bytes32 from a bytes array without bounds checking.
     *
     * NOTE: making this function internal would mean it could be used with memory unsafe offset, and marking the
     * assembly block as such would prevent some optimizations.
     */
    function _unsafeReadBytesOffset(bytes memory buffer, uint256 offset) private pure returns (bytes32 value) {
        // This is not memory safe in the general case, but all calls to this private function are within bounds.
        assembly ("memory-safe") {
            value := mload(add(buffer, add(0x20, offset)))
        }
    }
}


// File: lib/openzeppelin-contracts/contracts/utils/Arrays.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.3.0) (utils/Arrays.sol)
// This file was procedurally generated from scripts/generate/templates/Arrays.js.

pragma solidity ^0.8.20;

import {Comparators} from "./Comparators.sol";
import {SlotDerivation} from "./SlotDerivation.sol";
import {StorageSlot} from "./StorageSlot.sol";
import {Math} from "./math/Math.sol";

/**
 * @dev Collection of functions related to array types.
 */
library Arrays {
    using SlotDerivation for bytes32;
    using StorageSlot for bytes32;

    /**
     * @dev Sort an array of uint256 (in memory) following the provided comparator function.
     *
     * This function does the sorting "in place", meaning that it overrides the input. The object is returned for
     * convenience, but that returned value can be discarded safely if the caller has a memory pointer to the array.
     *
     * NOTE: this function's cost is `O(n · log(n))` in average and `O(n²)` in the worst case, with n the length of the
     * array. Using it in view functions that are executed through `eth_call` is safe, but one should be very careful
     * when executing this as part of a transaction. If the array being sorted is too large, the sort operation may
     * consume more gas than is available in a block, leading to potential DoS.
     *
     * IMPORTANT: Consider memory side-effects when using custom comparator functions that access memory in an unsafe way.
     */
    function sort(
        uint256[] memory array,
        function(uint256, uint256) pure returns (bool) comp
    ) internal pure returns (uint256[] memory) {
        _quickSort(_begin(array), _end(array), comp);
        return array;
    }

    /**
     * @dev Variant of {sort} that sorts an array of uint256 in increasing order.
     */
    function sort(uint256[] memory array) internal pure returns (uint256[] memory) {
        sort(array, Comparators.lt);
        return array;
    }

    /**
     * @dev Sort an array of address (in memory) following the provided comparator function.
     *
     * This function does the sorting "in place", meaning that it overrides the input. The object is returned for
     * convenience, but that returned value can be discarded safely if the caller has a memory pointer to the array.
     *
     * NOTE: this function's cost is `O(n · log(n))` in average and `O(n²)` in the worst case, with n the length of the
     * array. Using it in view functions that are executed through `eth_call` is safe, but one should be very careful
     * when executing this as part of a transaction. If the array being sorted is too large, the sort operation may
     * consume more gas than is available in a block, leading to potential DoS.
     *
     * IMPORTANT: Consider memory side-effects when using custom comparator functions that access memory in an unsafe way.
     */
    function sort(
        address[] memory array,
        function(address, address) pure returns (bool) comp
    ) internal pure returns (address[] memory) {
        sort(_castToUint256Array(array), _castToUint256Comp(comp));
        return array;
    }

    /**
     * @dev Variant of {sort} that sorts an array of address in increasing order.
     */
    function sort(address[] memory array) internal pure returns (address[] memory) {
        sort(_castToUint256Array(array), Comparators.lt);
        return array;
    }

    /**
     * @dev Sort an array of bytes32 (in memory) following the provided comparator function.
     *
     * This function does the sorting "in place", meaning that it overrides the input. The object is returned for
     * convenience, but that returned value can be discarded safely if the caller has a memory pointer to the array.
     *
     * NOTE: this function's cost is `O(n · log(n))` in average and `O(n²)` in the worst case, with n the length of the
     * array. Using it in view functions that are executed through `eth_call` is safe, but one should be very careful
     * when executing this as part of a transaction. If the array being sorted is too large, the sort operation may
     * consume more gas than is available in a block, leading to potential DoS.
     *
     * IMPORTANT: Consider memory side-effects when using custom comparator functions that access memory in an unsafe way.
     */
    function sort(
        bytes32[] memory array,
        function(bytes32, bytes32) pure returns (bool) comp
    ) internal pure returns (bytes32[] memory) {
        sort(_castToUint256Array(array), _castToUint256Comp(comp));
        return array;
    }

    /**
     * @dev Variant of {sort} that sorts an array of bytes32 in increasing order.
     */
    function sort(bytes32[] memory array) internal pure returns (bytes32[] memory) {
        sort(_castToUint256Array(array), Comparators.lt);
        return array;
    }

    /**
     * @dev Performs a quick sort of a segment of memory. The segment sorted starts at `begin` (inclusive), and stops
     * at end (exclusive). Sorting follows the `comp` comparator.
     *
     * Invariant: `begin <= end`. This is the case when initially called by {sort} and is preserved in subcalls.
     *
     * IMPORTANT: Memory locations between `begin` and `end` are not validated/zeroed. This function should
     * be used only if the limits are within a memory array.
     */
    function _quickSort(uint256 begin, uint256 end, function(uint256, uint256) pure returns (bool) comp) private pure {
        unchecked {
            if (end - begin < 0x40) return;

            // Use first element as pivot
            uint256 pivot = _mload(begin);
            // Position where the pivot should be at the end of the loop
            uint256 pos = begin;

            for (uint256 it = begin + 0x20; it < end; it += 0x20) {
                if (comp(_mload(it), pivot)) {
                    // If the value stored at the iterator's position comes before the pivot, we increment the
                    // position of the pivot and move the value there.
                    pos += 0x20;
                    _swap(pos, it);
                }
            }

            _swap(begin, pos); // Swap pivot into place
            _quickSort(begin, pos, comp); // Sort the left side of the pivot
            _quickSort(pos + 0x20, end, comp); // Sort the right side of the pivot
        }
    }

    /**
     * @dev Pointer to the memory location of the first element of `array`.
     */
    function _begin(uint256[] memory array) private pure returns (uint256 ptr) {
        assembly ("memory-safe") {
            ptr := add(array, 0x20)
        }
    }

    /**
     * @dev Pointer to the memory location of the first memory word (32bytes) after `array`. This is the memory word
     * that comes just after the last element of the array.
     */
    function _end(uint256[] memory array) private pure returns (uint256 ptr) {
        unchecked {
            return _begin(array) + array.length * 0x20;
        }
    }

    /**
     * @dev Load memory word (as a uint256) at location `ptr`.
     */
    function _mload(uint256 ptr) private pure returns (uint256 value) {
        assembly {
            value := mload(ptr)
        }
    }

    /**
     * @dev Swaps the elements memory location `ptr1` and `ptr2`.
     */
    function _swap(uint256 ptr1, uint256 ptr2) private pure {
        assembly {
            let value1 := mload(ptr1)
            let value2 := mload(ptr2)
            mstore(ptr1, value2)
            mstore(ptr2, value1)
        }
    }

    /// @dev Helper: low level cast address memory array to uint256 memory array
    function _castToUint256Array(address[] memory input) private pure returns (uint256[] memory output) {
        assembly {
            output := input
        }
    }

    /// @dev Helper: low level cast bytes32 memory array to uint256 memory array
    function _castToUint256Array(bytes32[] memory input) private pure returns (uint256[] memory output) {
        assembly {
            output := input
        }
    }

    /// @dev Helper: low level cast address comp function to uint256 comp function
    function _castToUint256Comp(
        function(address, address) pure returns (bool) input
    ) private pure returns (function(uint256, uint256) pure returns (bool) output) {
        assembly {
            output := input
        }
    }

    /// @dev Helper: low level cast bytes32 comp function to uint256 comp function
    function _castToUint256Comp(
        function(bytes32, bytes32) pure returns (bool) input
    ) private pure returns (function(uint256, uint256) pure returns (bool) output) {
        assembly {
            output := input
        }
    }

    /**
     * @dev Searches a sorted `array` and returns the first index that contains
     * a value greater or equal to `element`. If no such index exists (i.e. all
     * values in the array are strictly less than `element`), the array length is
     * returned. Time complexity O(log n).
     *
     * NOTE: The `array` is expected to be sorted in ascending order, and to
     * contain no repeated elements.
     *
     * IMPORTANT: Deprecated. This implementation behaves as {lowerBound} but lacks
     * support for repeated elements in the array. The {lowerBound} function should
     * be used instead.
     */
    function findUpperBound(uint256[] storage array, uint256 element) internal view returns (uint256) {
        uint256 low = 0;
        uint256 high = array.length;

        if (high == 0) {
            return 0;
        }

        while (low < high) {
            uint256 mid = Math.average(low, high);

            // Note that mid will always be strictly less than high (i.e. it will be a valid array index)
            // because Math.average rounds towards zero (it does integer division with truncation).
            if (unsafeAccess(array, mid).value > element) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        // At this point `low` is the exclusive upper bound. We will return the inclusive upper bound.
        if (low > 0 && unsafeAccess(array, low - 1).value == element) {
            return low - 1;
        } else {
            return low;
        }
    }

    /**
     * @dev Searches an `array` sorted in ascending order and returns the first
     * index that contains a value greater or equal than `element`. If no such index
     * exists (i.e. all values in the array are strictly less than `element`), the array
     * length is returned. Time complexity O(log n).
     *
     * See C++'s https://en.cppreference.com/w/cpp/algorithm/lower_bound[lower_bound].
     */
    function lowerBound(uint256[] storage array, uint256 element) internal view returns (uint256) {
        uint256 low = 0;
        uint256 high = array.length;

        if (high == 0) {
            return 0;
        }

        while (low < high) {
            uint256 mid = Math.average(low, high);

            // Note that mid will always be strictly less than high (i.e. it will be a valid array index)
            // because Math.average rounds towards zero (it does integer division with truncation).
            if (unsafeAccess(array, mid).value < element) {
                // this cannot overflow because mid < high
                unchecked {
                    low = mid + 1;
                }
            } else {
                high = mid;
            }
        }

        return low;
    }

    /**
     * @dev Searches an `array` sorted in ascending order and returns the first
     * index that contains a value strictly greater than `element`. If no such index
     * exists (i.e. all values in the array are strictly less than `element`), the array
     * length is returned. Time complexity O(log n).
     *
     * See C++'s https://en.cppreference.com/w/cpp/algorithm/upper_bound[upper_bound].
     */
    function upperBound(uint256[] storage array, uint256 element) internal view returns (uint256) {
        uint256 low = 0;
        uint256 high = array.length;

        if (high == 0) {
            return 0;
        }

        while (low < high) {
            uint256 mid = Math.average(low, high);

            // Note that mid will always be strictly less than high (i.e. it will be a valid array index)
            // because Math.average rounds towards zero (it does integer division with truncation).
            if (unsafeAccess(array, mid).value > element) {
                high = mid;
            } else {
                // this cannot overflow because mid < high
                unchecked {
                    low = mid + 1;
                }
            }
        }

        return low;
    }

    /**
     * @dev Same as {lowerBound}, but with an array in memory.
     */
    function lowerBoundMemory(uint256[] memory array, uint256 element) internal pure returns (uint256) {
        uint256 low = 0;
        uint256 high = array.length;

        if (high == 0) {
            return 0;
        }

        while (low < high) {
            uint256 mid = Math.average(low, high);

            // Note that mid will always be strictly less than high (i.e. it will be a valid array index)
            // because Math.average rounds towards zero (it does integer division with truncation).
            if (unsafeMemoryAccess(array, mid) < element) {
                // this cannot overflow because mid < high
                unchecked {
                    low = mid + 1;
                }
            } else {
                high = mid;
            }
        }

        return low;
    }

    /**
     * @dev Same as {upperBound}, but with an array in memory.
     */
    function upperBoundMemory(uint256[] memory array, uint256 element) internal pure returns (uint256) {
        uint256 low = 0;
        uint256 high = array.length;

        if (high == 0) {
            return 0;
        }

        while (low < high) {
            uint256 mid = Math.average(low, high);

            // Note that mid will always be strictly less than high (i.e. it will be a valid array index)
            // because Math.average rounds towards zero (it does integer division with truncation).
            if (unsafeMemoryAccess(array, mid) > element) {
                high = mid;
            } else {
                // this cannot overflow because mid < high
                unchecked {
                    low = mid + 1;
                }
            }
        }

        return low;
    }

    /**
     * @dev Access an array in an "unsafe" way. Skips solidity "index-out-of-range" check.
     *
     * WARNING: Only use if you are certain `pos` is lower than the array length.
     */
    function unsafeAccess(address[] storage arr, uint256 pos) internal pure returns (StorageSlot.AddressSlot storage) {
        bytes32 slot;
        assembly ("memory-safe") {
            slot := arr.slot
        }
        return slot.deriveArray().offset(pos).getAddressSlot();
    }

    /**
     * @dev Access an array in an "unsafe" way. Skips solidity "index-out-of-range" check.
     *
     * WARNING: Only use if you are certain `pos` is lower than the array length.
     */
    function unsafeAccess(bytes32[] storage arr, uint256 pos) internal pure returns (StorageSlot.Bytes32Slot storage) {
        bytes32 slot;
        assembly ("memory-safe") {
            slot := arr.slot
        }
        return slot.deriveArray().offset(pos).getBytes32Slot();
    }

    /**
     * @dev Access an array in an "unsafe" way. Skips solidity "index-out-of-range" check.
     *
     * WARNING: Only use if you are certain `pos` is lower than the array length.
     */
    function unsafeAccess(uint256[] storage arr, uint256 pos) internal pure returns (StorageSlot.Uint256Slot storage) {
        bytes32 slot;
        assembly ("memory-safe") {
            slot := arr.slot
        }
        return slot.deriveArray().offset(pos).getUint256Slot();
    }

    /**
     * @dev Access an array in an "unsafe" way. Skips solidity "index-out-of-range" check.
     *
     * WARNING: Only use if you are certain `pos` is lower than the array length.
     */
    function unsafeMemoryAccess(address[] memory arr, uint256 pos) internal pure returns (address res) {
        assembly {
            res := mload(add(add(arr, 0x20), mul(pos, 0x20)))
        }
    }

    /**
     * @dev Access an array in an "unsafe" way. Skips solidity "index-out-of-range" check.
     *
     * WARNING: Only use if you are certain `pos` is lower than the array length.
     */
    function unsafeMemoryAccess(bytes32[] memory arr, uint256 pos) internal pure returns (bytes32 res) {
        assembly {
            res := mload(add(add(arr, 0x20), mul(pos, 0x20)))
        }
    }

    /**
     * @dev Access an array in an "unsafe" way. Skips solidity "index-out-of-range" check.
     *
     * WARNING: Only use if you are certain `pos` is lower than the array length.
     */
    function unsafeMemoryAccess(uint256[] memory arr, uint256 pos) internal pure returns (uint256 res) {
        assembly {
            res := mload(add(add(arr, 0x20), mul(pos, 0x20)))
        }
    }

    /**
     * @dev Helper to set the length of a dynamic array. Directly writing to `.length` is forbidden.
     *
     * WARNING: this does not clear elements if length is reduced, of initialize elements if length is increased.
     */
    function unsafeSetLength(address[] storage array, uint256 len) internal {
        assembly ("memory-safe") {
            sstore(array.slot, len)
        }
    }

    /**
     * @dev Helper to set the length of a dynamic array. Directly writing to `.length` is forbidden.
     *
     * WARNING: this does not clear elements if length is reduced, of initialize elements if length is increased.
     */
    function unsafeSetLength(bytes32[] storage array, uint256 len) internal {
        assembly ("memory-safe") {
            sstore(array.slot, len)
        }
    }

    /**
     * @dev Helper to set the length of a dynamic array. Directly writing to `.length` is forbidden.
     *
     * WARNING: this does not clear elements if length is reduced, of initialize elements if length is increased.
     */
    function unsafeSetLength(uint256[] storage array, uint256 len) internal {
        assembly ("memory-safe") {
            sstore(array.slot, len)
        }
    }
}


// File: lib/l1-contracts/src/core/libraries/SlashPayloadLib.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {Errors} from "./Errors.sol";

/**
 * @title SlashPayloadLib
 * @author Aztec Labs
 * @notice Library for encoding immutable arguments for SlashPayloadCloneable contracts
 * @dev Provides utilities for encoding validator addresses and amounts into a format
 *      suitable for use with EIP-1167 minimal proxy clones with immutable arguments
 */
library SlashPayloadLib {
  /**
   * @notice Encode immutable arguments for SlashPayloadCloneable clones
   * @dev Encodes data in the format expected by SlashPayloadCloneable._getImmutableArgs()
   *      Layout: [validatorSelection(20 bytes)][arrayLength(32 bytes)][validators+amounts array data]
   *      Each validator entry: [address(20 bytes)][amount(12 bytes for uint96)]
   * @param _validatorSelection Address of the validator selection contract
   * @param _validators Array of validator addresses to slash
   * @param _amounts Array of amounts to slash for each validator (uint96 values)
   * @return Encoded arguments for use with cloneDeterministicWithImmutableArgs
   */
  function encodeImmutableArgs(address _validatorSelection, address[] memory _validators, uint96[] memory _amounts)
    internal
    pure
    returns (bytes memory)
  {
    require(
      _validators.length == _amounts.length, Errors.SlashPayload_ArraySizeMismatch(_validators.length, _amounts.length)
    );

    // Calculate total size: 20 bytes (address) + 32 bytes (length) + (20 + 12) * length
    uint256 dataSize = 52 + 32 * _validators.length;
    bytes memory data = new bytes(dataSize);

    assembly {
      let ptr := add(data, 0x20)

      // Store validator selection address (20 bytes)
      // Shift left by 96 bits (12 bytes) to align to the left of the 32-byte slot
      mstore(ptr, shl(96, _validatorSelection))
      ptr := add(ptr, 0x14) // Move 20 bytes forward

      // Store array length (32 bytes)
      mstore(ptr, mload(_validators))
      ptr := add(ptr, 0x20) // Move 32 bytes forward

      // Store validators and amounts
      let len := mload(_validators)
      let validatorsPtr := add(_validators, 0x20)
      let amountsPtr := add(_amounts, 0x20)

      for { let i := 0 } lt(i, len) { i := add(i, 1) } {
        // Store validator address (20 bytes)
        // Shift left by 96 bits to align to the left of the 32-byte slot
        mstore(ptr, shl(96, mload(add(validatorsPtr, mul(i, 0x20)))))
        ptr := add(ptr, 0x14) // Move 20 bytes forward

        // Store amount (12 bytes for uint96)
        // Shift left by 160 bits (20 bytes) to align to the left of the remaining space
        mstore(ptr, shl(160, mload(add(amountsPtr, mul(i, 0x20)))))
        ptr := add(ptr, 0x0c) // Move 12 bytes forward
      }
    }

    return data;
  }
}


// File: lib/l1-contracts/src/periphery/SlashPayloadCloneable.sol
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Aztec Labs.
pragma solidity >=0.8.27;

import {IStakingCore} from "@aztec/core/interfaces/IStaking.sol";
import {IPayload} from "@aztec/governance/interfaces/IPayload.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @notice Cloneable SlashPayload implementation that fetches arguments from immutable storage
 * @dev This contract is deployed once as an implementation and then cloned for each slash payload
 * Using EIP-1167 minimal proxy pattern with immutable arguments to save gas on deployment
 * @dev This contract can be further optimized by NOT storing the actions as immutables, and instead
 * store them in transient storage in the main contract, and just storing the round number here. Then,
 * when actions are requested, we just call back into the proposer and return them. Note that we cannot
 * just compute them on the fly on the proposer, since we need the committees to be provided as calldata.
 */
contract SlashPayloadCloneable is IPayload {
  using Clones for address;

  /**
   * @notice Get the actions to execute for this slash payload
   * @return actions Array of actions to slash validators
   */
  function getActions() external view override(IPayload) returns (IPayload.Action[] memory actions) {
    (address validatorSelection, address[] memory validators, uint96[] memory amounts) = _getImmutableArgs();

    actions = new IPayload.Action[](validators.length);

    for (uint256 i = 0; i < validators.length; i++) {
      actions[i] = IPayload.Action({
        target: validatorSelection,
        data: abi.encodeWithSelector(IStakingCore.slash.selector, validators[i], amounts[i])
      });
    }
  }

  /**
   * @notice Get the URI for this payload
   * @return The URI string
   */
  function getURI() external pure override(IPayload) returns (string memory) {
    return "SlashPayload";
  }

  /**
   * @notice Decode the immutable arguments stored in the clone's bytecode
   * @return validatorSelection The address of the validator selection contract
   * @return validators Array of validator addresses to slash
   * @return amounts Array of amounts to slash for each validator
   */
  function _getImmutableArgs()
    private
    view
    returns (address validatorSelection, address[] memory validators, uint96[] memory amounts)
  {
    // Fetch immutable args from clone's bytecode
    bytes memory args = Clones.fetchCloneArgs(address(this));

    // Decode the arguments
    // Layout: [validatorSelection(20 bytes)][arrayLength(32 bytes)][validators+amounts array data]
    assembly {
      // Read validator selection address (first 20 bytes)
      validatorSelection := shr(96, mload(add(args, 0x20)))

      // Read array length (next 32 bytes after the address)
      let arrayLen := mload(add(args, 0x34))

      // Allocate memory for validators array
      validators := mload(0x40)
      mstore(validators, arrayLen)
      let validatorsData := add(validators, 0x20)

      // Allocate memory for amounts array
      amounts := add(validatorsData, mul(arrayLen, 0x20))
      mstore(amounts, arrayLen)
      let amountsData := add(amounts, 0x20)

      // Update free memory pointer
      mstore(0x40, add(amountsData, mul(arrayLen, 0x20)))

      // Copy validator addresses and amounts
      let srcPtr := add(args, 0x54) // Start after validatorSelection + arrayLength

      for { let i := 0 } lt(i, arrayLen) { i := add(i, 1) } {
        // Read validator address (20 bytes)
        let validator := shr(96, mload(srcPtr))
        mstore(add(validatorsData, mul(i, 0x20)), validator)
        srcPtr := add(srcPtr, 0x14)

        // Read amount (12 bytes for uint96)
        let amount := shr(160, mload(srcPtr))
        mstore(add(amountsData, mul(i, 0x20)), amount)
        srcPtr := add(srcPtr, 0x0c)
      }
    }
  }
}


// File: lib/openzeppelin-contracts/contracts/proxy/Clones.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.3.0) (proxy/Clones.sol)

pragma solidity ^0.8.20;

import {Create2} from "../utils/Create2.sol";
import {Errors} from "../utils/Errors.sol";

/**
 * @dev https://eips.ethereum.org/EIPS/eip-1167[ERC-1167] is a standard for
 * deploying minimal proxy contracts, also known as "clones".
 *
 * > To simply and cheaply clone contract functionality in an immutable way, this standard specifies
 * > a minimal bytecode implementation that delegates all calls to a known, fixed address.
 *
 * The library includes functions to deploy a proxy using either `create` (traditional deployment) or `create2`
 * (salted deterministic deployment). It also includes functions to predict the addresses of clones deployed using the
 * deterministic method.
 */
library Clones {
    error CloneArgumentsTooLong();

    /**
     * @dev Deploys and returns the address of a clone that mimics the behavior of `implementation`.
     *
     * This function uses the create opcode, which should never revert.
     */
    function clone(address implementation) internal returns (address instance) {
        return clone(implementation, 0);
    }

    /**
     * @dev Same as {xref-Clones-clone-address-}[clone], but with a `value` parameter to send native currency
     * to the new contract.
     *
     * NOTE: Using a non-zero value at creation will require the contract using this function (e.g. a factory)
     * to always have enough balance for new deployments. Consider exposing this function under a payable method.
     */
    function clone(address implementation, uint256 value) internal returns (address instance) {
        if (address(this).balance < value) {
            revert Errors.InsufficientBalance(address(this).balance, value);
        }
        assembly ("memory-safe") {
            // Cleans the upper 96 bits of the `implementation` word, then packs the first 3 bytes
            // of the `implementation` address with the bytecode before the address.
            mstore(0x00, or(shr(0xe8, shl(0x60, implementation)), 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000))
            // Packs the remaining 17 bytes of `implementation` with the bytecode after the address.
            mstore(0x20, or(shl(0x78, implementation), 0x5af43d82803e903d91602b57fd5bf3))
            instance := create(value, 0x09, 0x37)
        }
        if (instance == address(0)) {
            revert Errors.FailedDeployment();
        }
    }

    /**
     * @dev Deploys and returns the address of a clone that mimics the behavior of `implementation`.
     *
     * This function uses the create2 opcode and a `salt` to deterministically deploy
     * the clone. Using the same `implementation` and `salt` multiple times will revert, since
     * the clones cannot be deployed twice at the same address.
     */
    function cloneDeterministic(address implementation, bytes32 salt) internal returns (address instance) {
        return cloneDeterministic(implementation, salt, 0);
    }

    /**
     * @dev Same as {xref-Clones-cloneDeterministic-address-bytes32-}[cloneDeterministic], but with
     * a `value` parameter to send native currency to the new contract.
     *
     * NOTE: Using a non-zero value at creation will require the contract using this function (e.g. a factory)
     * to always have enough balance for new deployments. Consider exposing this function under a payable method.
     */
    function cloneDeterministic(
        address implementation,
        bytes32 salt,
        uint256 value
    ) internal returns (address instance) {
        if (address(this).balance < value) {
            revert Errors.InsufficientBalance(address(this).balance, value);
        }
        assembly ("memory-safe") {
            // Cleans the upper 96 bits of the `implementation` word, then packs the first 3 bytes
            // of the `implementation` address with the bytecode before the address.
            mstore(0x00, or(shr(0xe8, shl(0x60, implementation)), 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000))
            // Packs the remaining 17 bytes of `implementation` with the bytecode after the address.
            mstore(0x20, or(shl(0x78, implementation), 0x5af43d82803e903d91602b57fd5bf3))
            instance := create2(value, 0x09, 0x37, salt)
        }
        if (instance == address(0)) {
            revert Errors.FailedDeployment();
        }
    }

    /**
     * @dev Computes the address of a clone deployed using {Clones-cloneDeterministic}.
     */
    function predictDeterministicAddress(
        address implementation,
        bytes32 salt,
        address deployer
    ) internal pure returns (address predicted) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x38), deployer)
            mstore(add(ptr, 0x24), 0x5af43d82803e903d91602b57fd5bf3ff)
            mstore(add(ptr, 0x14), implementation)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73)
            mstore(add(ptr, 0x58), salt)
            mstore(add(ptr, 0x78), keccak256(add(ptr, 0x0c), 0x37))
            predicted := and(keccak256(add(ptr, 0x43), 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    /**
     * @dev Computes the address of a clone deployed using {Clones-cloneDeterministic}.
     */
    function predictDeterministicAddress(
        address implementation,
        bytes32 salt
    ) internal view returns (address predicted) {
        return predictDeterministicAddress(implementation, salt, address(this));
    }

    /**
     * @dev Deploys and returns the address of a clone that mimics the behavior of `implementation` with custom
     * immutable arguments. These are provided through `args` and cannot be changed after deployment. To
     * access the arguments within the implementation, use {fetchCloneArgs}.
     *
     * This function uses the create opcode, which should never revert.
     */
    function cloneWithImmutableArgs(address implementation, bytes memory args) internal returns (address instance) {
        return cloneWithImmutableArgs(implementation, args, 0);
    }

    /**
     * @dev Same as {xref-Clones-cloneWithImmutableArgs-address-bytes-}[cloneWithImmutableArgs], but with a `value`
     * parameter to send native currency to the new contract.
     *
     * NOTE: Using a non-zero value at creation will require the contract using this function (e.g. a factory)
     * to always have enough balance for new deployments. Consider exposing this function under a payable method.
     */
    function cloneWithImmutableArgs(
        address implementation,
        bytes memory args,
        uint256 value
    ) internal returns (address instance) {
        if (address(this).balance < value) {
            revert Errors.InsufficientBalance(address(this).balance, value);
        }
        bytes memory bytecode = _cloneCodeWithImmutableArgs(implementation, args);
        assembly ("memory-safe") {
            instance := create(value, add(bytecode, 0x20), mload(bytecode))
        }
        if (instance == address(0)) {
            revert Errors.FailedDeployment();
        }
    }

    /**
     * @dev Deploys and returns the address of a clone that mimics the behavior of `implementation` with custom
     * immutable arguments. These are provided through `args` and cannot be changed after deployment. To
     * access the arguments within the implementation, use {fetchCloneArgs}.
     *
     * This function uses the create2 opcode and a `salt` to deterministically deploy the clone. Using the same
     * `implementation`, `args` and `salt` multiple times will revert, since the clones cannot be deployed twice
     * at the same address.
     */
    function cloneDeterministicWithImmutableArgs(
        address implementation,
        bytes memory args,
        bytes32 salt
    ) internal returns (address instance) {
        return cloneDeterministicWithImmutableArgs(implementation, args, salt, 0);
    }

    /**
     * @dev Same as {xref-Clones-cloneDeterministicWithImmutableArgs-address-bytes-bytes32-}[cloneDeterministicWithImmutableArgs],
     * but with a `value` parameter to send native currency to the new contract.
     *
     * NOTE: Using a non-zero value at creation will require the contract using this function (e.g. a factory)
     * to always have enough balance for new deployments. Consider exposing this function under a payable method.
     */
    function cloneDeterministicWithImmutableArgs(
        address implementation,
        bytes memory args,
        bytes32 salt,
        uint256 value
    ) internal returns (address instance) {
        bytes memory bytecode = _cloneCodeWithImmutableArgs(implementation, args);
        return Create2.deploy(value, salt, bytecode);
    }

    /**
     * @dev Computes the address of a clone deployed using {Clones-cloneDeterministicWithImmutableArgs}.
     */
    function predictDeterministicAddressWithImmutableArgs(
        address implementation,
        bytes memory args,
        bytes32 salt,
        address deployer
    ) internal pure returns (address predicted) {
        bytes memory bytecode = _cloneCodeWithImmutableArgs(implementation, args);
        return Create2.computeAddress(salt, keccak256(bytecode), deployer);
    }

    /**
     * @dev Computes the address of a clone deployed using {Clones-cloneDeterministicWithImmutableArgs}.
     */
    function predictDeterministicAddressWithImmutableArgs(
        address implementation,
        bytes memory args,
        bytes32 salt
    ) internal view returns (address predicted) {
        return predictDeterministicAddressWithImmutableArgs(implementation, args, salt, address(this));
    }

    /**
     * @dev Get the immutable args attached to a clone.
     *
     * - If `instance` is a clone that was deployed using `clone` or `cloneDeterministic`, this
     *   function will return an empty array.
     * - If `instance` is a clone that was deployed using `cloneWithImmutableArgs` or
     *   `cloneDeterministicWithImmutableArgs`, this function will return the args array used at
     *   creation.
     * - If `instance` is NOT a clone deployed using this library, the behavior is undefined. This
     *   function should only be used to check addresses that are known to be clones.
     */
    function fetchCloneArgs(address instance) internal view returns (bytes memory) {
        bytes memory result = new bytes(instance.code.length - 45); // revert if length is too short
        assembly ("memory-safe") {
            extcodecopy(instance, add(result, 32), 45, mload(result))
        }
        return result;
    }

    /**
     * @dev Helper that prepares the initcode of the proxy with immutable args.
     *
     * An assembly variant of this function requires copying the `args` array, which can be efficiently done using
     * `mcopy`. Unfortunately, that opcode is not available before cancun. A pure solidity implementation using
     * abi.encodePacked is more expensive but also more portable and easier to review.
     *
     * NOTE: https://eips.ethereum.org/EIPS/eip-170[EIP-170] limits the length of the contract code to 24576 bytes.
     * With the proxy code taking 45 bytes, that limits the length of the immutable args to 24531 bytes.
     */
    function _cloneCodeWithImmutableArgs(
        address implementation,
        bytes memory args
    ) private pure returns (bytes memory) {
        if (args.length > 24531) revert CloneArgumentsTooLong();
        return
            abi.encodePacked(
                hex"61",
                uint16(args.length + 45),
                hex"3d81600a3d39f3363d3d373d3d3d363d73",
                implementation,
                hex"5af43d82803e903d91602b57fd5bf3",
                args
            );
    }
}


// File: lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (utils/StorageSlot.sol)
// This file was procedurally generated from scripts/generate/templates/StorageSlot.js.

pragma solidity ^0.8.20;

/**
 * @dev Library for reading and writing primitive types to specific storage slots.
 *
 * Storage slots are often used to avoid storage conflict when dealing with upgradeable contracts.
 * This library helps with reading and writing to such slots without the need for inline assembly.
 *
 * The functions in this library return Slot structs that contain a `value` member that can be used to read or write.
 *
 * Example usage to set ERC-1967 implementation slot:
 * ```solidity
 * contract ERC1967 {
 *     // Define the slot. Alternatively, use the SlotDerivation library to derive the slot.
 *     bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
 *
 *     function _getImplementation() internal view returns (address) {
 *         return StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value;
 *     }
 *
 *     function _setImplementation(address newImplementation) internal {
 *         require(newImplementation.code.length > 0);
 *         StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value = newImplementation;
 *     }
 * }
 * ```
 *
 * TIP: Consider using this library along with {SlotDerivation}.
 */
library StorageSlot {
    struct AddressSlot {
        address value;
    }

    struct BooleanSlot {
        bool value;
    }

    struct Bytes32Slot {
        bytes32 value;
    }

    struct Uint256Slot {
        uint256 value;
    }

    struct Int256Slot {
        int256 value;
    }

    struct StringSlot {
        string value;
    }

    struct BytesSlot {
        bytes value;
    }

    /**
     * @dev Returns an `AddressSlot` with member `value` located at `slot`.
     */
    function getAddressSlot(bytes32 slot) internal pure returns (AddressSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `BooleanSlot` with member `value` located at `slot`.
     */
    function getBooleanSlot(bytes32 slot) internal pure returns (BooleanSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Bytes32Slot` with member `value` located at `slot`.
     */
    function getBytes32Slot(bytes32 slot) internal pure returns (Bytes32Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Uint256Slot` with member `value` located at `slot`.
     */
    function getUint256Slot(bytes32 slot) internal pure returns (Uint256Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Int256Slot` with member `value` located at `slot`.
     */
    function getInt256Slot(bytes32 slot) internal pure returns (Int256Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `StringSlot` with member `value` located at `slot`.
     */
    function getStringSlot(bytes32 slot) internal pure returns (StringSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `StringSlot` representation of the string storage pointer `store`.
     */
    function getStringSlot(string storage store) internal pure returns (StringSlot storage r) {
        assembly ("memory-safe") {
            r.slot := store.slot
        }
    }

    /**
     * @dev Returns a `BytesSlot` with member `value` located at `slot`.
     */
    function getBytesSlot(bytes32 slot) internal pure returns (BytesSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `BytesSlot` representation of the bytes storage pointer `store`.
     */
    function getBytesSlot(bytes storage store) internal pure returns (BytesSlot storage r) {
        assembly ("memory-safe") {
            r.slot := store.slot
        }
    }
}


// File: lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (utils/introspection/IERC165.sol)

pragma solidity ^0.8.20;

/**
 * @dev Interface of the ERC-165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[ERC].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[ERC section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}


// File: lib/openzeppelin-contracts/contracts/utils/Comparators.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (utils/Comparators.sol)

pragma solidity ^0.8.20;

/**
 * @dev Provides a set of functions to compare values.
 *
 * _Available since v5.1._
 */
library Comparators {
    function lt(uint256 a, uint256 b) internal pure returns (bool) {
        return a < b;
    }

    function gt(uint256 a, uint256 b) internal pure returns (bool) {
        return a > b;
    }
}


// File: lib/openzeppelin-contracts/contracts/utils/Create2.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (utils/Create2.sol)

pragma solidity ^0.8.20;

import {Errors} from "./Errors.sol";

/**
 * @dev Helper to make usage of the `CREATE2` EVM opcode easier and safer.
 * `CREATE2` can be used to compute in advance the address where a smart
 * contract will be deployed, which allows for interesting new mechanisms known
 * as 'counterfactual interactions'.
 *
 * See the https://eips.ethereum.org/EIPS/eip-1014#motivation[EIP] for more
 * information.
 */
library Create2 {
    /**
     * @dev There's no code to deploy.
     */
    error Create2EmptyBytecode();

    /**
     * @dev Deploys a contract using `CREATE2`. The address where the contract
     * will be deployed can be known in advance via {computeAddress}.
     *
     * The bytecode for a contract can be obtained from Solidity with
     * `type(contractName).creationCode`.
     *
     * Requirements:
     *
     * - `bytecode` must not be empty.
     * - `salt` must have not been used for `bytecode` already.
     * - the factory must have a balance of at least `amount`.
     * - if `amount` is non-zero, `bytecode` must have a `payable` constructor.
     */
    function deploy(uint256 amount, bytes32 salt, bytes memory bytecode) internal returns (address addr) {
        if (address(this).balance < amount) {
            revert Errors.InsufficientBalance(address(this).balance, amount);
        }
        if (bytecode.length == 0) {
            revert Create2EmptyBytecode();
        }
        assembly ("memory-safe") {
            addr := create2(amount, add(bytecode, 0x20), mload(bytecode), salt)
            // if no address was created, and returndata is not empty, bubble revert
            if and(iszero(addr), not(iszero(returndatasize()))) {
                let p := mload(0x40)
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
        }
        if (addr == address(0)) {
            revert Errors.FailedDeployment();
        }
    }

    /**
     * @dev Returns the address where a contract will be stored if deployed via {deploy}. Any change in the
     * `bytecodeHash` or `salt` will result in a new destination address.
     */
    function computeAddress(bytes32 salt, bytes32 bytecodeHash) internal view returns (address) {
        return computeAddress(salt, bytecodeHash, address(this));
    }

    /**
     * @dev Returns the address where a contract will be stored if deployed via {deploy} from a contract located at
     * `deployer`. If `deployer` is this contract's address, returns the same value as {computeAddress}.
     */
    function computeAddress(bytes32 salt, bytes32 bytecodeHash, address deployer) internal pure returns (address addr) {
        assembly ("memory-safe") {
            let ptr := mload(0x40) // Get free memory pointer

            // |                   | ↓ ptr ...  ↓ ptr + 0x0B (start) ...  ↓ ptr + 0x20 ...  ↓ ptr + 0x40 ...   |
            // |-------------------|---------------------------------------------------------------------------|
            // | bytecodeHash      |                                                        CCCCCCCCCCCCC...CC |
            // | salt              |                                      BBBBBBBBBBBBB...BB                   |
            // | deployer          | 000000...0000AAAAAAAAAAAAAAAAAAA...AA                                     |
            // | 0xFF              |            FF                                                             |
            // |-------------------|---------------------------------------------------------------------------|
            // | memory            | 000000...00FFAAAAAAAAAAAAAAAAAAA...AABBBBBBBBBBBBB...BBCCCCCCCCCCCCC...CC |
            // | keccak(start, 85) |            ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑ |

            mstore(add(ptr, 0x40), bytecodeHash)
            mstore(add(ptr, 0x20), salt)
            mstore(ptr, deployer) // Right-aligned with 12 preceding garbage bytes
            let start := add(ptr, 0x0b) // The hashed data starts at the final garbage byte which we will set to 0xff
            mstore8(start, 0xff)
            addr := and(keccak256(start, 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}


// File: lib/openzeppelin-contracts/contracts/utils/Errors.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (utils/Errors.sol)

pragma solidity ^0.8.20;

/**
 * @dev Collection of common custom errors used in multiple contracts
 *
 * IMPORTANT: Backwards compatibility is not guaranteed in future versions of the library.
 * It is recommended to avoid relying on the error API for critical functionality.
 *
 * _Available since v5.1._
 */
library Errors {
    /**
     * @dev The ETH balance of the account is not enough to perform the operation.
     */
    error InsufficientBalance(uint256 balance, uint256 needed);

    /**
     * @dev A call to an address target failed. The target may have reverted.
     */
    error FailedCall();

    /**
     * @dev The deployment failed.
     */
    error FailedDeployment();

    /**
     * @dev A necessary precompile is missing.
     */
    error MissingPrecompile(address);
}


