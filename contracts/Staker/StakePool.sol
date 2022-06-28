// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Utilities.sol";

interface IPARA {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
}

contract StakePool is AccessControl, Utilities {
    using SafeERC20 for IERC20;
 
    // para token
    address internal para;
    IPARA internal PARA;

    // rewards pool - 33% of the staked PARA will be sent to this pool
    address rewardsPoolAddress;

    constructor(address _para, uint256 _rewardsPerSecond, address _rewardsPoolAddress) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        // _grantRole(MINTER_ROLE, msg.sender);

        // the governance token
        para = _para;
        PARA = IPARA(_para);
        rewardsPoolAddress = _rewardsPoolAddress;

        addPool(_rewardsPerSecond);
    }

    function stake(uint256 newStakedParas, uint256 newStakedDays) public {
        /* Make sure staked amount is non-zero */
        require(newStakedParas != 0, "PARA: amount must be non-zero");

        /* enforce the minimum stake time */
        require(newStakedDays >= MIN_STAKE_DAYS, "PARA: newStakedDays lower than minimum");

        /* enforce the maximum stake time */
        require(newStakedDays <= MAX_STAKE_DAYS, "PARA: newStakedDays higher than maximum");

        Pool memory vPool = updatePool();

        uint256 newStakeShares = _stakeStartBonusParas(newStakedParas, newStakedDays);
        uint256 rewardDebt = (newStakedParas * vPool.accParaPerShare) / PARA_PRECISION;

        // get user position
        UserPosition storage userPosition = userPositions[msg.sender];
        userPosition.rewardDebt = rewardDebt;
        userPosition.lastStakeId += 1;
        userPosition.stakeSharesTotal += newStakeShares;
        userPosition.totalAmount += newStakedParas;

        /*
            The startStake timestamp will always be part-way through the current
            day, so it needs to be rounded-up to the next day to ensure all
            stakes align with the same fixed calendar days. The current day is
            already rounded-down, so rounded-up is current day + 1.
        */
        uint256 newPooledDay = block.timestamp / 1 days + 1;

        /* Create Stake */
        uint256 newStakeId = userPosition.lastStakeId;
        _addStake(
            userPosition.stakes,
            newStakeId,
            newStakedParas,
            newStakeShares,
            newPooledDay,
            newStakedDays
        );

        emit StartStake(
            uint256(block.timestamp),
            msg.sender,
            newStakeId,
            newStakedParas,
            uint256(newStakedDays)
        );

        // update pool share
        virtualPool.totalPooled += newStakedParas;

        /* Transfer staked Paras to contract */
        IERC20(para).safeTransferFrom(msg.sender, address(this), newStakedParas);
        
        // burn 33% of the amount
        PARA.burn(newStakedParas * 33 / 100);

        // send the other 33% to the rewards pool
        IERC20(para).safeTransfer(rewardsPoolAddress, newStakedParas * 33 / 100);
    }

    /**
     * @dev PUBLIC FACING: Closes a stake. The order of the stake list can change so
     * a stake id is used to reject stale indexes.
     * @param stakeIndex Index of stake within stake list
     * @param stakeIdParam The stake's id
     */
    function endStake(uint256 stakeIndex, uint256 stakeIdParam)
        external
    {
        UserPosition storage userPosition = userPositions[msg.sender];
        Stake[] storage stakeListRef = userPosition.stakes;

        /* require() is more informative than the default assert() */
        require(stakeListRef.length != 0, "PARA: Empty stake list");
        require(stakeIndex < stakeListRef.length, "PARA: stakeIndex invalid");

        uint256 servedDays = 0;
        Stake storage stk = stakeListRef[stakeIndex];

        // update pool status
        updatePool();
        virtualPool.totalPooled -= stk.stakedParas;

        bool prevUnpooled = (stk.unpooledDay != 0);
        uint256 stakeReturn;
        uint256 payout = 0;
        uint256 penalty = 0;
        uint256 cappedPenalty = 0;
        uint256 currentDay = block.timestamp / 1 days;

        if (currentDay >= stk.pooledDay) {
            if (prevUnpooled) {
                /* Previously unpooled in goodAccounting(), so must have served full term */
                servedDays = stk.stakedDays;
            } else {
                _unpoolStake(userPosition, stk);

                servedDays = currentDay - stk.pooledDay;
                if (servedDays > stk.stakedDays) {
                    servedDays = stk.stakedDays;
                }
            }

            (stakeReturn, payout, penalty, cappedPenalty) = calcStakeReturn(userPosition, stk, servedDays);
        } else {
            /* Stake hasn't been added to the global pool yet, so no penalties or rewards apply */
            userPosition.stakeSharesTotal -= stk.stakeShares;
            stakeReturn = stk.stakedParas;
        }

        emit EndStake(
            uint256(block.timestamp),
            msg.sender,
            stakeIdParam,
            payout,
            penalty,
            uint256(servedDays)
        );

        if (stakeReturn != 0) {
            /* Transfer stake return from contract back to staker */
            IERC20(para).safeTransferFrom(address(this), msg.sender, stakeReturn);
        }

        _removeStakeFromList(stakeListRef, stakeIndex);
    }

    /**
     * @dev Calculate stakeShares for a new stake, including any bonus
     * @param newStakedParas Number of Paras to stake
     * @param newStakedDays Number of days to stake
     */
    
    function _stakeStartBonusParas(uint256 newStakedParas, uint256 newStakedDays)
        private
        pure
        returns (uint256 bonusParas)
    {
        uint256 cappedExtraDays = 0;

        /* Must be more than 1 day for Longer-Pays-Better */
        if (newStakedDays > 1) {
            cappedExtraDays = newStakedDays <= MAX_STAKE_DAYS ? newStakedDays - 1 : MAX_STAKE_DAYS;
        }

        uint256 cappedStakedParas = newStakedParas <= LPB_H_CAP_PARA
            ? newStakedParas
            : LPB_H_CAP_PARA;

        bonusParas = newStakedParas * cappedExtraDays / LPB_H + newStakedParas * cappedStakedParas / LPB_D;
        return bonusParas;
    }

    function calcStakeReturn(UserPosition memory usr, Stake memory st, uint256 servedDays)
        public
        view
        returns (uint256 stakeReturn, uint256 payout, uint256 penalty, uint256 cappedPenalty)
    {
        if (servedDays < st.stakedDays) {
            (payout, penalty) = _calcPayoutAndEarlyPenalty(
                usr,
                st.pooledDay,
                st.stakedDays,
                servedDays,
                st.stakedParas,
                st.stakeShares
            );
            stakeReturn = st.stakedParas + payout;
        } else {
            payout = calcPayoutRewards(usr.stakeSharesTotal, st.stakedParas, st.stakeShares, st.pooledDay, st.pooledDay + servedDays);
            stakeReturn = st.stakedParas + payout;
            penalty = 0;
        }

        // get rewards based on the pool shares
        uint256 accParaPerShare = virtualPool.accParaPerShare;
        uint256 tokenSupply = IERC20(para).balanceOf(address(this));

        if (block.timestamp > virtualPool.lastRewardTime && tokenSupply != 0) {
            uint256 passedTime = block.timestamp - virtualPool.lastRewardTime;
            uint256 paraReward = passedTime * virtualPool.rewardsPerSecond;
            accParaPerShare =
                accParaPerShare +
                (paraReward * PARA_PRECISION) /
                tokenSupply;
        }
        uint256 pendingPoolShare =
            (((usr.totalAmount * accParaPerShare) / PARA_PRECISION)) -
            usr.rewardDebt;

        stakeReturn += pendingPoolShare;
        payout += pendingPoolShare;

        if (penalty != 0) {
            if (penalty > stakeReturn) {
                /* Cannot have a negative stake return */
                cappedPenalty = stakeReturn;
                stakeReturn = 0;
            } else {
                /* Remove penalty from the stake return */
                cappedPenalty = penalty;
                stakeReturn -= cappedPenalty;
            }
        }

        return (stakeReturn, payout, penalty, cappedPenalty);
    }

    /**
     * @dev Calculates served payout and early penalty for early unstake
     * @param pooledDayParam param from stake
     * @param stakedDaysParam param from stake
     * @param servedDays number of days actually served
     * @param stakeSharesParam param from stake
     * @return payout 1: payout Paras; 
     * @return penalty 2: penalty Paras;
     */
    function _calcPayoutAndEarlyPenalty(
        UserPosition memory usr,
        uint256 pooledDayParam,
        uint256 stakedDaysParam,
        uint256 servedDays,
        uint256 stakedParasParam,
        uint256 stakeSharesParam
    )
        private
        pure
        returns (uint256 payout, uint256 penalty)
    {
        uint256 servedEndDay = pooledDayParam + servedDays;

        /* 50% of stakedDays (rounded up) with a minimum applied */
        uint256 penaltyDays = stakedDaysParam / 2 + stakedDaysParam % 2;

        if (penaltyDays < servedDays) {
            /*
                Simplified explanation of intervals where end-day is non-inclusive:
                penalty:    [pooledDay  ...  penaltyEndDay)
                delta:                      [penaltyEndDay  ...  servedEndDay)
                payout:     [pooledDay  .......................  servedEndDay)
            */
            uint256 penaltyEndDay = pooledDayParam + penaltyDays;
            penalty = calcPayoutRewards(usr.stakeSharesTotal, stakedParasParam, stakeSharesParam, pooledDayParam, penaltyEndDay);

            uint256 delta = calcPayoutRewards(usr.stakeSharesTotal, stakedParasParam, stakeSharesParam, penaltyEndDay, servedEndDay);
            payout = penalty + delta;
            return (payout, penalty);
        }

        /* penaltyDays >= servedDays  */
        payout = calcPayoutRewards(usr.stakeSharesTotal, stakedParasParam, stakeSharesParam, pooledDayParam, servedEndDay);

        if (penaltyDays == servedDays) {
            penalty = payout;
        } else {
            /*
                (penaltyDays > servedDays) means not enough days served, so fill the
                penalty days with the average payout from only the days that were served.
            */
            penalty = payout * penaltyDays / servedDays;
        }
        return (payout, penalty);
    }

    /**
     * @dev PUBLIC FACING: Calculates total stake payout including rewards for a multi-day range
     * @param stakeSharesTotal param from usr to calculate bonuses
     * @param stakedParas param from stake to calculate bonus
     * @param stakeSharesParam param from stake to calculate bonuses for
     * @param beginDay first day to calculate bonuses for
     * @param endDay last day (non-inclusive) of range to calculate bonuses for
     * @return payout Hearts
     */
    function calcPayoutRewards(uint256 stakeSharesTotal, uint256 stakedParas, uint256 stakeSharesParam, uint256 beginDay, uint256 endDay)
        public
        pure
        returns (uint256 payout)
    {
        payout += (endDay - beginDay) * stakedParas * stakeSharesParam / stakeSharesTotal;
        return payout;
    }
    
    function addPool(uint256 _rewardsPerSecond) public onlyRole(DEFAULT_ADMIN_ROLE) {
        virtualPool = Pool({
            totalPooled: 0,
            rewardsPerSecond: _rewardsPerSecond,
            accParaPerShare: 0,
            lastRewardTime: block.timestamp
        });
    }
    
    function updatePool() internal returns (Pool memory _virtualPool) {
        uint256 tokenSupply = IERC20(para).balanceOf(address(this));
        uint256 accParaPerShare;
        if (block.timestamp > virtualPool.lastRewardTime) {
            if (tokenSupply > 0) {
                uint256 passedTime = block.timestamp - virtualPool.lastRewardTime;
                uint256 paraReward = passedTime * virtualPool.rewardsPerSecond;
                accParaPerShare =
                    virtualPool.accParaPerShare +
                    (paraReward * PARA_PRECISION) /
                    tokenSupply;
            }
            uint256 lastRewardTime = block.timestamp;

            virtualPool.lastRewardTime = lastRewardTime;
            virtualPool.accParaPerShare = accParaPerShare;

            return virtualPool;
        }
    }

    function _unpoolStake(UserPosition storage usr, Stake storage st)
        internal
    {
        usr.totalAmount -= st.stakedParas;
        usr.stakeSharesTotal -= st.stakeShares;
        st.unpooledDay = block.timestamp / 1 days;
    }

}