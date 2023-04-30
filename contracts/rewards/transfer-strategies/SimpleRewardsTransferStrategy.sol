// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import {ITransferStrategyBase} from '../interfaces/ITransferStrategyBase.sol';
import {TransferStrategyBase} from './TransferStrategyBase.sol';
import {GPv2SafeERC20} from '@aave/core-v3/contracts/dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import {IERC20} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol';

contract SimpleRewardsTransferStrategy is TransferStrategyBase {
  using GPv2SafeERC20 for IERC20;

  constructor(
    address incentivesController,
    address rewardsAdmin
  ) TransferStrategyBase(incentivesController, rewardsAdmin) {}

  /// @inheritdoc TransferStrategyBase
  function performTransfer(
    address to,
    address reward,
    uint256 amount
  ) external override(TransferStrategyBase) onlyIncentivesController returns (bool) {
    IERC20(reward).safeTransfer(to, amount);
    return true;
  }
}
