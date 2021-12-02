pragma solidity 0.8.10;

import {VersionedInitializable} from '@aave/core-v3/contracts/protocol/libraries/aave-upgradeability/VersionedInitializable.sol';
import {IScaledBalanceToken} from '@aave/core-v3/contracts/interfaces/IScaledBalanceToken.sol';
import {DistributionManagerV2} from './DistributionManagerV2.sol';
import {IAaveIncentivesControllerV2} from './interfaces/IAaveIncentivesControllerV2.sol';
import {ITransferStrategyBase} from './interfaces/ITransferStrategyBase.sol';
import {DistributionTypesV2} from './libraries/DistributionTypesV2.sol';
import {IEACAggregatorProxy} from '../misc/interfaces/IEACAggregatorProxy.sol';

/**
 * @title IncentivesControllerV2
 * @notice Abstract contract template to build Distributors contracts for ERC20 rewards to protocol participants
 * @author Aave
 **/
contract IncentivesControllerV2 is
  DistributionManagerV2,
  VersionedInitializable,
  IAaveIncentivesControllerV2
{
  uint256 public constant REVISION = 1;

  // This mapping allows whitelisted addresses to claim on behalf of others
  // useful for contracts that hold tokens to be rewarded but don't have any native logic to claim Liquidity Mining rewards
  mapping(address => address) internal _authorizedClaimers;

  // reward => transfer strategy implementation contract
  // The TransferStrategy contract abstracts the logic regarding
  // the source of the reward and how to transfer it to the user.
  mapping(address => ITransferStrategyBase) internal _transferStrategy;

  // This mapping contains the price oracle per reward.
  // A price oracle is enforced for integrators to be able to show incentives at
  // the current Aave UI without the need to setup an external price registry
  // At the moment of reward configuration, the Incentives Controller performs
  // a check to see if the provided reward oracle contains `latestAnswer`.
  mapping(address => IEACAggregatorProxy) internal _rewardOracle;

  modifier onlyAuthorizedClaimers(address claimer, address user) {
    require(_authorizedClaimers[user] == claimer, 'CLAIMER_UNAUTHORIZED');
    _;
  }

  constructor(address emissionManager) DistributionManagerV2(emissionManager) {}

  /**
   * @dev Empty initialize for IncentivesControllerV2
   **/
  function initialize() external initializer {}

  /// @inheritdoc IAaveIncentivesControllerV2
  function getClaimer(address user) external view override returns (address) {
    return _authorizedClaimers[user];
  }

  /**
   * @dev Returns the revision of the implementation contract
   * @return uint256, current revision version
   */
  function getRevision() internal pure override returns (uint256) {
    return REVISION;
  }

  /// @inheritdoc IAaveIncentivesControllerV2
  function getRewardOracle(address reward) external view override returns (address) {
    return address(_rewardOracle[reward]);
  }

  /// @inheritdoc IAaveIncentivesControllerV2
  function getTransferStrategy(address reward) external view override returns (address) {
    return address(_transferStrategy[reward]);
  }

  /// @inheritdoc IAaveIncentivesControllerV2
  function configureAssets(DistributionTypesV2.RewardsConfigInput[] memory config)
    external
    override
    onlyEmissionManager
  {
    for (uint256 i = 0; i < config.length; i++) {
      // Get the current Scaled Total Supply of AToken or Debt token
      config[i].totalSupply = IScaledBalanceToken(config[i].asset).scaledTotalSupply();

      // Install TransferStrategy logic at IncentivesController
      _installTransferStrategy(config[i].reward, config[i].transferStrategy);

      // Set reward oracle, enforces input oracle to have latestPrice function
      _setRewardOracle(config[i].reward, config[i].rewardOracle);
    }
    _configureAssets(config);
  }

  /// @inheritdoc IAaveIncentivesControllerV2
  function setTransferStrategy(address reward, ITransferStrategyBase transferStrategy)
    external
    onlyEmissionManager
  {
    _installTransferStrategy(reward, transferStrategy);
  }

  /// @inheritdoc IAaveIncentivesControllerV2
  function setRewardOracle(address reward, IEACAggregatorProxy rewardOracle)
    external
    onlyEmissionManager
  {
    _setRewardOracle(reward, rewardOracle);
  }

  /// @inheritdoc IAaveIncentivesControllerV2
  function handleAction(
    address user,
    uint256 totalSupply,
    uint256 userBalance
  ) external override {
    _updateUserRewardsPerAssetInternal(msg.sender, user, userBalance, totalSupply);
  }

  /// @inheritdoc IAaveIncentivesControllerV2
  function claimRewards(
    address[] calldata assets,
    uint256 amount,
    address to,
    address reward
  ) external override returns (uint256) {
    require(to != address(0), 'INVALID_TO_ADDRESS');
    return _claimRewards(assets, amount, msg.sender, msg.sender, to, reward);
  }

  /// @inheritdoc IAaveIncentivesControllerV2
  function claimRewardsOnBehalf(
    address[] calldata assets,
    uint256 amount,
    address user,
    address to,
    address reward
  ) external override onlyAuthorizedClaimers(msg.sender, user) returns (uint256) {
    require(user != address(0), 'INVALID_USER_ADDRESS');
    require(to != address(0), 'INVALID_TO_ADDRESS');
    return _claimRewards(assets, amount, msg.sender, user, to, reward);
  }

  /// @inheritdoc IAaveIncentivesControllerV2
  function claimRewardsToSelf(
    address[] calldata assets,
    uint256 amount,
    address reward
  ) external override returns (uint256) {
    return _claimRewards(assets, amount, msg.sender, msg.sender, msg.sender, reward);
  }

  /// @inheritdoc IAaveIncentivesControllerV2
  function claimAllRewards(address[] calldata assets, address to)
    external
    override
    returns (address[] memory rewardsList, uint256[] memory claimedAmounts)
  {
    require(to != address(0), 'INVALID_TO_ADDRESS');
    return _claimAllRewards(assets, msg.sender, msg.sender, to);
  }

  /// @inheritdoc IAaveIncentivesControllerV2
  function claimAllRewardsOnBehalf(
    address[] calldata assets,
    address user,
    address to
  )
    external
    override
    onlyAuthorizedClaimers(msg.sender, user)
    returns (address[] memory rewardsList, uint256[] memory claimedAmounts)
  {
    require(user != address(0), 'INVALID_USER_ADDRESS');
    require(to != address(0), 'INVALID_TO_ADDRESS');
    return _claimAllRewards(assets, msg.sender, user, to);
  }

  /// @inheritdoc IAaveIncentivesControllerV2
  function claimAllRewardsToSelf(address[] calldata assets)
    external
    override
    returns (address[] memory rewardsList, uint256[] memory claimedAmounts)
  {
    return _claimAllRewards(assets, msg.sender, msg.sender, msg.sender);
  }

  /// @inheritdoc IAaveIncentivesControllerV2
  function setClaimer(address user, address caller) external override onlyEmissionManager {
    _authorizedClaimers[user] = caller;
    emit ClaimerSet(user, caller);
  }

  /**
   * @dev Get usage statistics of a list of assets that supports IScaledBalanceToken interface
   * @param assets List of assets to retrieve user balance and total supply
   * @param user Address of the user
   * @return userState contains a list of usage statistics like user balance and total supply of the assets passed as argument
   */
  function _getUserStake(address[] calldata assets, address user)
    internal
    view
    override
    returns (DistributionTypesV2.UserAssetStatsInput[] memory userState)
  {
    userState = new DistributionTypesV2.UserAssetStatsInput[](assets.length);
    for (uint256 i = 0; i < assets.length; i++) {
      userState[i].underlyingAsset = assets[i];
      (userState[i].userBalance, userState[i].totalSupply) = IScaledBalanceToken(assets[i])
        .getScaledUserBalanceAndSupply(user);
    }
    return userState;
  }

  /**
   * @dev Claims one type of reward for an user on behalf, on all the assets of the lending pool, accumulating the pending rewards.
   * @param assets List of assets to check eligible distributions before claiming rewards
   * @param amount Amount of rewards to claim
   * @param claimer Address of the claimer who claims rewards on behalf of user
   * @param user Address to check and claim rewards
   * @param to Address that will be receiving the rewards
   * @param reward Address of the reward token
   * @return Rewards claimed
   **/
  function _claimRewards(
    address[] calldata assets,
    uint256 amount,
    address claimer,
    address user,
    address to,
    address reward
  ) internal returns (uint256) {
    if (amount == 0) {
      return 0;
    }
    uint256 unclaimedRewards = _usersUnclaimedRewards[user][reward];

    if (amount > unclaimedRewards) {
      _distributeRewards(user, _getUserStake(assets, user));
      unclaimedRewards = _usersUnclaimedRewards[user][reward];
    }

    if (unclaimedRewards == 0) {
      return 0;
    }

    uint256 amountToClaim = amount > unclaimedRewards ? unclaimedRewards : amount;
    _usersUnclaimedRewards[user][reward] = unclaimedRewards - amountToClaim; // Safe due to the previous line

    _transferRewards(to, reward, amountToClaim);
    emit RewardsClaimed(user, reward, to, claimer, amountToClaim);

    return amountToClaim;
  }

  /**
   * @dev Claims one type of reward for an user on behalf, on all the assets of the lending pool, accumulating the pending rewards.
   * @param assets List of assets to check eligible distributions before claiming rewards
   * @param claimer Address of the claimer on behalf of user
   * @param user Address to check and claim rewards
   * @param to Address that will be receiving the rewards
   * @return
   *   rewardsList List of reward addresses
   *   claimedAmount List of claimed amounts, follows "rewardsList" items order
   **/
  function _claimAllRewards(
    address[] calldata assets,
    address claimer,
    address user,
    address to
  ) internal returns (address[] memory rewardsList, uint256[] memory claimedAmounts) {
    _distributeRewards(user, _getUserStake(assets, user));

    for (uint256 i = 0; i < _rewardsList.length; i++) {
      address reward = _rewardsList[i];
      uint256 rewardAmount = _usersUnclaimedRewards[user][reward];

      rewardsList[i] = reward;
      claimedAmounts[i] = rewardAmount;

      if (rewardAmount != 0) {
        _usersUnclaimedRewards[user][reward] = 0;
        _transferRewards(to, reward, rewardAmount);
        emit RewardsClaimed(user, reward, to, claimer, rewardAmount);
      }
    }
    return (rewardsList, claimedAmounts);
  }

  /**
   * @dev Function to transfer rewards to the desired account using delegatecall and
   * @param to Account address to send the rewards
   * @param reward Address of the reward token
   * @param amount Amount of rewards to transfer
   */
  function _transferRewards(
    address to,
    address reward,
    uint256 amount
  ) internal {
    ITransferStrategyBase transferStrategy = _transferStrategy[reward];

    require(address(transferStrategy) != address(0), 'Transfer implementation can not be empty');

    (bool success, bytes memory returnData) = address(transferStrategy).call(
      abi.encodeWithSelector(transferStrategy.performTransfer.selector, to, reward, amount)
    );

    require(abi.decode(returnData, (bool)) == true && success == true, 'Transfer error');
  }

  /**
   * @dev Returns true if `account` is a contract.
   * @param account The address of the account
   * @return bool, true if contract, false otherwise
   */
  function _isContract(address account) internal view returns (bool) {
    // This method relies on extcodesize, which returns 0 for contracts in
    // construction, since the code is only stored at the end of the
    // constructor execution.

    uint256 size;
    // solhint-disable-next-line no-inline-assembly
    assembly {
      size := extcodesize(account)
    }
    return size > 0;
  }

  /**
   * @dev Internal function to call the optional install hook at the TransferStrategy
   * @param reward The address of the reward token
   * @param transferStrategy The address of the reward TransferStrategy
   */
  function _installTransferStrategy(address reward, ITransferStrategyBase transferStrategy)
    internal
  {
    require(
      _isContract(address(transferStrategy)) == true,
      'TransferStrategy Logic address must be a contract'
    );

    _transferStrategy[reward] = transferStrategy;

    emit TransferStrategyInstalled(reward, address(transferStrategy));
  }

  /**
   * @dev internal function to update the Price Oracle of a reward token. The Price Oracle must follow Chainlink IEACAggregatorProxy interface.
   * @notice The Price Oracle of a reward is used for displaying correct data about the incentives at the UI frontend.
   * @param reward The address of the reward token
   * @param rewardOracle The address of the price oracle
   */

  function _setRewardOracle(address reward, IEACAggregatorProxy rewardOracle) internal {
    require(rewardOracle.latestAnswer() > 0, 'Oracle must return price');
    _rewardOracle[reward] = rewardOracle;
    emit RewardOracleUpdated(reward, address(rewardOracle));
  }
}
