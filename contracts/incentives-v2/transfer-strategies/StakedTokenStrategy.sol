// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.8.10;

import {IStakedToken} from '../interfaces/IStakedToken.sol';
import {ITransferStrategy} from '../interfaces/ITransferStrategy.sol';
import {TransferStrategyStorage} from './TransferStrategyStorage.sol';
import {SafeTransferLib, ERC20} from '@rari-capital/solmate/src/utils/SafeTransferLib.sol';

/**
 * @title StakedTokenTransferStrategy
 * @notice Transfer strategy that stakes the rewards into a staking contract and transfers the staking contract token.
 * @author Aave
 **/
contract StakedTokenTransferStrategy is TransferStrategyStorage, ITransferStrategy {
  using SafeTransferLib for ERC20;

  IStakedToken public immutable STAKE_CONTRACT;
  address public immutable UNDERLYING_TOKEN;

  constructor(IStakedToken stakeToken) TransferStrategyStorage() {
    STAKE_CONTRACT = stakeToken;
    UNDERLYING_TOKEN = STAKE_CONTRACT.STAKED_TOKEN();
  }

  /// @inheritdoc ITransferStrategy
  function installHook(bytes memory) external override onlyDelegateCall returns (bool) {
    ERC20(UNDERLYING_TOKEN).safeApprove(address(STAKE_CONTRACT), 0);
    ERC20(UNDERLYING_TOKEN).safeApprove(address(STAKE_CONTRACT), type(uint256).max);

    return true;
  }

  /// @inheritdoc ITransferStrategy
  function performTransfer(
    address to,
    address reward,
    uint256 amount
  ) external override onlyDelegateCall returns (bool) {
    require(reward == address(STAKE_CONTRACT), 'Reward token is not the staked token');

    STAKE_CONTRACT.stake(to, amount);

    return true;
  }
}
