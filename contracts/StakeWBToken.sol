// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract StakeWBToken is Ownable {
    using SafeERC20 for IERC20;

    // Per Account staking data structure
    struct stakingInfo {
        uint128 amount; // Amount of tokens staked by the account
        uint128 unclaimedDynReward; // Allocated but Unclaimed dynamic reward
        uint128 maxObligation; // The fixed reward obligation, assuming user holds until contract expiry.
        uint32 lastClaimTime; // used for delta time for claims
    }

    mapping(address => stakingInfo) userStakes;

    // **** Constants set in Constructor ****
    // ERC-20 Token we are staking
    IERC20 immutable token;

    // Timestamp of when staking rewards start, contract expires "rewardLifetime" after this.
    uint32 rewardStartTime;

    // Reward period of the contract
    uint32 immutable rewardLifetime;

    // Fixed APR, expressed in Basis Points (BPS - 0.01%)
    uint32 immutable fixedAPR;

    // max allowable number of tokens that can be Staked to the contract by all users
    // if exceeded - abort the txn
    uint128 immutable maxTokensStakable;

    //total number of tokens that has been staked by all the users.
    uint128 totalTokensStaked;

    //tokens remaining to be distributed among stake holders - initially deposited by the contract owner
    uint128 public fixedRewardsAvailable;

    // Total dynamic tokens deposited, but not yet allocated
    uint128 public dynamicTokensToAllocate;

    // Total of the fixed staking obligation (unclaimed tokens) to stakers, assuming they stake until the contract expires.
    // This amount is adjusted with each stake/unstake.
    uint128 fixedObligation;

    // Total Dynamic Tokens across all wallets
    uint128 public dynamicTokensAllocated;

    /// @notice Persist initial state on construction
    /// @param _tokenAddr contract address of the token being staked
    /// @param _maxStakable Maximum number of tokens stakable by the contract in basic units
    constructor(address _tokenAddr, uint128 _maxStakable) {
        token = IERC20(_tokenAddr);
        maxTokensStakable = _maxStakable;
        rewardLifetime = 365 days;
        fixedAPR = 500; // 5% in Basis Points
        rewardStartTime = 0; // Rewards are not started immediately
    }

    /// @notice Initiates the reward generation period
    /// @dev contract & rewards finish "rewardLifetime" after this.
    /// @return Starting Timestamp
    function setRewardStartTime() external onlyOwner returns (uint256) {
        require(rewardStartTime == 0, "Rewards already started");

        rewardStartTime = uint32(block.timestamp);
        return rewardStartTime;
    }

    /// @notice User function for staking tokens
    /// @param _amount Number of tokens to stake in basic units (n * 10**decimals)
    function stake(uint128 _amount) external {
        require(
            (rewardStartTime == 0) ||
                (block.timestamp <= rewardStartTime + rewardLifetime),
            "Staking period is over"
        );

        require(
            totalTokensStaked + _amount <= maxTokensStakable,
            "Max staking limit exceeded"
        );

        // Use .lastClaimTime == 0 as test for Account existence - initialise if a new address
        if (userStakes[msg.sender].lastClaimTime == 0) {
            userStakes[msg.sender].lastClaimTime = uint32(block.timestamp);
        }

        _claim(); //must claim before updating amount
        userStakes[msg.sender].amount += _amount;
        totalTokensStaked += _amount;

        _updateFixedObligation(msg.sender);

        token.safeTransferFrom(msg.sender, address(this), _amount);
        emit StakeTokens(msg.sender, _amount);
    }

    /// @notice Unstake tokens from the contract. Unstaking will also trigger a claim of all allocated rewards.
    /// @dev remaining tokens after unstake will accrue rewards based on the new balance.
    /// @param _amount Number of tokens to stake in basic units (n * 10**decimals)
    function unstake(uint128 _amount) external {
        require(userStakes[msg.sender].amount > 0, "Nothing to unstake");
        require(
            _amount <= userStakes[msg.sender].amount,
            "Unstake Amount greater than Stake"
        );
        _claim();
        userStakes[msg.sender].amount -= _amount;
        totalTokensStaked -= _amount;
        _updateFixedObligation(msg.sender);

        token.safeTransfer(msg.sender, _amount);
        emit UnstakeTokens(msg.sender, _amount);
    }

    /// @notice Claim all outstanding rewards from the contract
    function claim() external {
        require(
            rewardStartTime != 0,
            "Nothing to claim, Rewards have not yet started"
        );
        _claim();
        _updateFixedObligation(msg.sender);
    }

    /// @notice Update the end of contract obligation (user and Total)
    /// @dev This obligation determines the number of tokens claimable by owner at end of contract
    /// @param _address The address to update
    function _updateFixedObligation(address _address) private {
        // Use the entire rewardlifetime if rewards have not yet started
        uint128 newMaxObligation;
        uint128 effectiveTime;

        if (rewardStartTime == 0) {
            effectiveTime = 0;
        } else if (
            uint128(block.timestamp) > rewardStartTime + rewardLifetime
        ) {
            effectiveTime = rewardStartTime + rewardLifetime;
        } else {
            effectiveTime = uint128(block.timestamp);
        }

        newMaxObligation =
            (((userStakes[_address].amount * fixedAPR) / 10000) *
                (rewardStartTime + rewardLifetime - effectiveTime)) /
            rewardLifetime;

        // Adjust the total obligation
        fixedObligation =
            fixedObligation -
            userStakes[_address].maxObligation +
            newMaxObligation;
        userStakes[_address].maxObligation = newMaxObligation;
    }

    /// @notice private claim all accumulated outstanding tokens back to the callers wallet
    function _claim() private {
        // Return with no action if the staking period has not commenced yet.
        if (rewardStartTime == 0) {
            return;
        }

        uint32 lastClaimTime = userStakes[msg.sender].lastClaimTime;

        // If the user staked before the start time was set, update the stake time to be the now known start Time
        if (lastClaimTime < rewardStartTime) {
            lastClaimTime = rewardStartTime;
        }

        // Calculation includes Fixed 5% APR + Dynamic

        // Adjust claim time to never exceed the reward end date
        uint32 claimTime = (block.timestamp < rewardStartTime + rewardLifetime)
            ? uint32(block.timestamp)
            : rewardStartTime + rewardLifetime;

        uint128 fixedClaimAmount = (((userStakes[msg.sender].amount *
            fixedAPR) / 10000) * (claimTime - lastClaimTime)) / rewardLifetime;

        uint128 dynamicClaimAmount = userStakes[msg.sender].unclaimedDynReward;
        dynamicTokensAllocated -= dynamicClaimAmount;

        uint128 totalClaim = fixedClaimAmount + dynamicClaimAmount;

        require(
            fixedRewardsAvailable >= fixedClaimAmount,
            "Insufficient Fixed Rewards available"
        );

        if (totalClaim > 0) {
            token.safeTransfer(msg.sender, totalClaim);
        }

        if (fixedClaimAmount > 0) {
            fixedRewardsAvailable -= uint128(fixedClaimAmount); // decrease the tokens remaining to reward
        }
        userStakes[msg.sender].lastClaimTime = uint32(claimTime);

        if (dynamicClaimAmount > 0) {
            userStakes[msg.sender].unclaimedDynReward = 0;
        }
        // _updateFixedObligation(msg.sender); - refactored into stake, claim, unstake

        emit ClaimReward(msg.sender, fixedClaimAmount, dynamicClaimAmount);
    }

    /// Deposit tokens for the current epoch's dynamic reward, then Allocate at end of epoch
    /// Step 1 depositDynamicReward
    /// Step 2 allocatDynamicReward

    /// @notice owner Deposit deposit of dynamic reward for later Allocation
    /// @param _amount Number of tokens to deposit in basic units (n * 10**decimals)
    function depositDynamicReward(uint128 _amount) external onlyOwner {
        token.safeTransferFrom(msg.sender, address(this), _amount);

        dynamicTokensToAllocate += _amount;

        emit DepositDynamicReward(msg.sender, _amount);
    }

    /// Step 2 - each week, an off-chain process will call this function to allocate the rewards to the staked wallets
    /// A robust mechanism is required to be sure all addresses are allocated funds and that the allocation matches the tokens
    ///  previously deposited (in step 1)
    /// Multiple calls may be made per round if necessary (e.g. if the arrays grow too big)
    /// @param _addresses[] Array of addresses to receive
    /// @param _amounts[] Number of tokens to deposit in basic units (n * 10**decimals)
    /// @param _totalAmount total number of tokens to Allocate in this call
    function allocateDynamicReward(
        address[] memory _addresses,
        uint128[] memory _amounts,
        uint128 _totalAmount
    ) external onlyOwner {
        uint256 _calcdTotal = 0;

        require(
            _addresses.length == _amounts.length,
            "_addresses[] and _amounts[] must be the same length"
        );
        require(
            dynamicTokensToAllocate >= _totalAmount,
            "Not enough tokens available to allocate"
        );

        for (uint256 i = 0; i < _addresses.length; i++) {
            userStakes[_addresses[i]].unclaimedDynReward += _amounts[i];
            _calcdTotal += _amounts[i];
        }
        require(
            _calcdTotal == _totalAmount,
            "Sum of amounts does not equal total"
        );

        dynamicTokensToAllocate -= _totalAmount; // adjust remaining balance to allocate

        // ToDo - Remove after testing
        dynamicTokensAllocated += _totalAmount;
    }

    /// @notice Team deposit of the Fixed staking reward for later distribution
    /// @notice This transfer is intended be done once, in full, before the commencement of the staking period
    /// @param _amount Number of tokens to deposit in basic units (n * 10**decimals)
    function depositFixedReward(uint128 _amount)
        external
        onlyOwner
        returns (uint128)
    {
        fixedRewardsAvailable += _amount;

        token.safeTransferFrom(msg.sender, address(this), _amount);

        emit DepositFixedReward(msg.sender, _amount);

        return fixedRewardsAvailable;
    }

    /// @notice Withdraw unused Fixed reward tokens, deposited at the beginning of the contract period.
    /// @notice Withdrawal is allowed only after the contract period has elapsed and then only allow withdrawal of unallocated tokens.
    function withdrawFixedReward() external onlyOwner returns (uint256) {
        require(
            block.timestamp > rewardStartTime + rewardLifetime,
            "Staking period is not yet over"
        );
        require(
            fixedRewardsAvailable >= fixedObligation,
            "Insufficient Fixed Rewards available"
        );
        uint128 tokensToWithdraw = fixedRewardsAvailable - fixedObligation;

        fixedRewardsAvailable -= tokensToWithdraw;

        token.safeTransfer(msg.sender, tokensToWithdraw);

        emit WithdrawFixedReward(msg.sender, tokensToWithdraw);

        return tokensToWithdraw;
    }

    //Inspection methods

    // Contract Inspection methods
    function getRewardStartTime() external view returns (uint256) {
        return rewardStartTime;
    }

    function getMaxStakingLimit() public view returns (uint256) {
        return maxTokensStakable;
    }

    function getRewardLifetime() public view returns (uint256) {
        return rewardLifetime;
    }

    function getTotalStaked() external view  returns (uint256) {
        return totalTokensStaked;
    }

    function getFixedObligation() public view returns (uint256) {
        return fixedObligation;
    }

    // Account Inspection Methods
    function getTokensStaked(address _addr) public view returns (uint256) {
        return userStakes[_addr].amount;
    }

    function getStakedPercentage(address _addr)
        public
        view
        returns (uint256, uint256)
    {
        return (totalTokensStaked, userStakes[_addr].amount);
    }

    function getStakeInfo(address _addr)
        public
        view
        returns (
            uint128 amount, // Amount of tokens staked by the account
            uint128 unclaimedFixedReward, // Allocated but Unclaimed fixed reward
            uint128 unclaimedDynReward, // Allocated but Unclaimed dynamic reward
            uint128 maxObligation, // The fixed reward obligation, assuming user holds until contract expiry.
            uint32 lastClaimTime, // used for delta time for claims
            uint32 claimtime // show the effective claim time
        )
    {
        //added to view the dynamic obligation asso. with addr.
        uint128 fixedClaimAmount;
        uint32 claimTime;
        stakingInfo memory s = userStakes[_addr];
        if (rewardStartTime > 0) {
            claimTime = (block.timestamp < rewardStartTime + rewardLifetime)
                ? uint32(block.timestamp)
                : rewardStartTime + rewardLifetime;

            fixedClaimAmount =
                (((s.amount * fixedAPR) / 10000) *
                    (claimTime - s.lastClaimTime)) /
                rewardLifetime;
        } else {
            // rewards have not started
            fixedClaimAmount = 0;
        }

        return (
            s.amount,
            fixedClaimAmount,
            s.unclaimedDynReward,
            s.maxObligation,
            s.lastClaimTime,
            claimTime
        );
    }

    function getStakeTokenAddress() public view returns (IERC20) {
        return token;
    }

    // Events
    event DepositFixedReward(address indexed from, uint256 amount);
    event DepositDynamicReward(address indexed from, uint256 amount);
    event WithdrawFixedReward(address indexed to, uint256 amount);

    event StakeTokens(address indexed from, uint256 amount);
    event UnstakeTokens(address indexed to, uint256 amount);
    event ClaimReward(
        address indexed to,
        uint256 fixedAmount,
        uint256 dynamicAmount
    );
}
