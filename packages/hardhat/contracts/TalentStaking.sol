pragma solidity ^0.8.4; // todo: need to deploy 0.8.4
pragma experimental ABIEncoderV2;
//SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
//import "../utility/ReentrancyGuard.sol";

import "./interfaces/ITDAOToken.sol";
import "./interfaces/IVETDAOToken.sol";

import "hardhat/console.sol";

/**
 * @title TokenRecover
 * @dev Allow to recover any ERC20 sent into the contract for error
 */
contract TokenRecover is Ownable {
    /**
     * @dev Remember that only owner can call so be careful when use on contracts generated from other contracts.
     * @param tokenAddress The token contract address
     * @param tokenAmount Number of tokens to be sent
     */
    function recoverERC20(address tokenAddress, uint256 tokenAmount) public onlyOwner {
        IERC20(tokenAddress).transfer(owner(), tokenAmount);
    }
}

/// @title Talent Stake Pool Contract
/// @author Jaxcoder
/// @notice Swaps Talent for veTalent and earn rewards on your Talent deposit
/// @dev There is a 1:1 ratio on swaps
// ReentrancyGuard, 
contract PharoStakePool is AccessControl, TokenRecover {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address private asset;

    // The Token Interfaces
    ITDAOToken public talentToken;
    IVETDAOToken public veTalentToken;

    uint256 public currentApy;

    // Burn tokens address
    address public constant burnAddress = 0x000000000000000000000000000000000000dEaD;

    // Fee taken on all rewards and sent to
    // the reserve pool. 1% or 100 basis points.
    // Updateable by the DAO.
    uint256 public rewardFee = 100;

    // The block number when PHRO bonus mining starts.
    uint256 public startBlock;
    uint256 public bonusEndBlock;

    // PHRO per block rewarded
    // todo: need to calculate this a bit better... SMG??
    // This is also adjustable by the DAO
    uint256 public PHRO_PER_BLOCK = 2 ether;

    // Bonus muliplier for early gpharo makers.
    uint256 public constant BONUS_MULTIPLIER = 2;

    // uint256 constant MAX_PHRO_SUPPLY = 1000000000 ether; // 1 Billion

    // Total must equal the sum of all allocation points in all pools
    uint256 public totalAllocationPoint = 0;

    uint256 public numOfPools;

    // Roles
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant DAO_ROLE = keccak256("DAO_ROLE");

    /// @dev Structs
    struct StakerInfo {
        uint256 amount; // How many tokens the user has deposited
        uint256 rewardDebt; // Reward Debt: the amount of PHRO tokens
        // pending reward = (user.amount * pool.accTalentPerShare) - user.rewardDebt
        // Whenever a user deposits or withdraws tokens to a pool. Here's what happens:
        //   1. Pools deposit sum gets updated
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    struct PoolInfo {
        address asset; // Address of the pools token contract
        uint256 allocationPoint; // How many allocation points assigned to this pool. PHROs to dist per block.
        uint256 lastRewardBlock; // last block that PHRO dist occurred
        uint256 depositSum; // the total of all deposits in this pool
        uint256 accTalentPerShare; // Accumulated PHRO per share, times 1e12. See below
    }

    /// @dev sum of all deposits currently held in the pools when and if we add more...
    mapping(address => uint) depositSums;
    mapping(uint256 => PoolInfo) public pools;
    mapping(uint256 => mapping(address => StakerInfo)) public stakerInfo;

    /// @dev Events
    event DepositMade(address indexed user, uint256 indexed pid, uint256 amount);
    event Deposited(address user, uint256 amount, uint256 timestamp);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event LogSetPool(uint256 indexed pid, uint256 allocPoint);
    event UpdateEmissionRate(address indexed sender, uint256 talentPerBlock);
    event BurnAddressUpdated(address indexed sender, address indexed burnAddress);
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event Entered(address indexed user, uint256 amount, uint256 timestamp);
    event Exited(address indexed user, uint256 amount, uint256 timestamp);

        // ReentrancyGuard()
    constructor (
        uint256 _startBlock,
        uint256 _bonusEndBlock,
        address _talentToken,
        address _veTalentToken
    )
        public
    {
        startBlock = _startBlock;
        bonusEndBlock = _bonusEndBlock;
        talentToken = ITDAOToken(_talentToken);
        veTalentToken = IVETDAOToken(_veTalentToken);

        // ** add the talent/veTalent stake pool with 100 allocation,
        // this will be the only pool even though we have
        // the ability to add more. Who knows, the future is bright :)
        addStakePool(10, _talentToken);

        _setupRole(OPERATOR_ROLE, msg.sender);
        _setupRole(DAO_ROLE, msg.sender);
        // transferOwnership(0x3f15B8c6F9939879Cb030D6dd935348E57109637);
    }

    // /// @dev updates the PHRO per block emission rate
    // function updateEmissionRate(uint256 _pharoPerBlock)
    //     public
    //     onlyOwner
    // {
    //     require(hasRole(DAO_ROLE, msg.sender), "PharoStakePool :: not in the DAO role, sorry...");
    //     PHRO_PER_BLOCK = _pharoPerBlock;
    //     emit UpdateEmissionRate(msg.sender, _pharoPerBlock);
    // }

    /// @notice contractsupports sending ETH directly
    receive() external payable { }


    /// @dev Add a new pool with an LP or Single token. Can only be called by the owner.
    function addStakePool(uint256 _allocationPoint, address _asset)
        public
        onlyOwner
        returns(bool success)
    {
        require(_allocationPoint > 0 && _allocationPoint < 101, "Outside the bounds of the system");
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocationPoint = totalAllocationPoint.add(_allocationPoint);

        PoolInfo storage pool = pools[numOfPools++];
        pool.asset = _asset;
        pool.allocationPoint = _allocationPoint;
        pool.lastRewardBlock = lastRewardBlock;
        pool.depositSum = 0;

        return true;
    }

    // /// @dev Update the given pool's PHRO allocation point. Can only be called by the owner.
    // function set(uint256 _poolId, uint256 _allocPoint)
    //     public 
    //     onlyOwner 
    // {
    //     PoolInfo storage pool = pools[_poolId];
    //     totalAllocationPoint = totalAllocationPoint.sub(pools[_poolId].allocationPoint).add(
    //         _allocPoint
    //     );
    //     pool.allocationPoint = _allocPoint;
    // }

    /// @dev Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        if (_to <= bonusEndBlock) {
            return _to.sub(_from).mul(BONUS_MULTIPLIER);
        } else if (_from >= bonusEndBlock) {
            return _to.sub(_from);
        } else {
            return
                bonusEndBlock.sub(_from).mul(BONUS_MULTIPLIER).add(
                    _to.sub(bonusEndBlock)
                );
        }
    }

    /// @dev view funciton to see pending PHRO on front-end
    function pendingPhro(uint256 _pid, address _staker)
        public
        view
        returns (uint256)
    {
        PoolInfo storage pool = pools[_pid];
        StakerInfo storage staker = stakerInfo[_pid][_staker];
        uint256 accTalentPerShare = pool.accTalentPerShare;
        uint256 lpSupply = talentToken.balanceOf(address(this));
        
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(
                pool.lastRewardBlock,
                block.number
            );
            uint256 talentReward = multiplier
                .mul(PHRO_PER_BLOCK)
                .mul(pool.allocationPoint)
                .div(totalAllocationPoint);
            console.log("Pending Talent for user", talentReward);
            accTalentPerShare = accTalentPerShare.add(
                talentReward.mul(1e12).div(lpSupply)
            );
            console.log("Acc TALENT per share ", accTalentPerShare);
        }

        return staker.amount.mul(accTalentPerShare).div(1e12).sub(staker.rewardDebt);
    }

    /// @dev updates the pool rewards values
    function updatePool(uint256 _poolId) public {
        PoolInfo storage pool = pools[_poolId];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = talentToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 talentReward = multiplier
            .mul(PHRO_PER_BLOCK)
            .mul(pool.allocationPoint)
            .div(totalAllocationPoint);
        talentToken.mintTokensTo(address(this), talentReward);
        pool.accTalentPerShare = pool.accTalentPerShare.add(
            talentReward.mul(1e12).div(lpSupply)
        );
        pool.lastRewardBlock = block.number;
    }

    /// @dev deposit PHRO tokens to receive gPHRO tokens and earn rewards
    function deposit(uint256 _poolId, uint256 _amount) public {
        PoolInfo storage pool = pools[_poolId];
        StakerInfo storage user = stakerInfo[_poolId][msg.sender];

        updatePool(_poolId);
        if (user.amount > 0) {
            uint256 pending = user
                .amount
                .mul(pool.accTalentPerShare)
                .div(1e12)
                .sub(user.rewardDebt);
            safeTalentTransfer(msg.sender, pending);
            console.log("Transferred ", pending, " PRHO rewards");
        }

        talentToken.transferFrom(
            address(msg.sender),
            address(this),
            _amount
        );
        pool.depositSum = pool.depositSum.add(_amount);
        console.log("Transferred ", _amount, " PHRO");
        // veTalentToken.mintStakerTokens(msg.sender, _amount);
        safeVeTalentTransfer(msg.sender, _amount);
        console.log("Transferred ", _amount, " gPHRO");
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accTalentPerShare).div(1e12);
        
        emit Deposited(msg.sender, _amount, block.timestamp);
    }

    /// @dev withdraw your PHRO tokens for the equal amount of gPHRO you 
    ///     want to trade in.
    function withdraw(uint256 _poolId, uint256 _amount) public {
        PoolInfo storage pool = pools[_poolId];
        StakerInfo storage user = stakerInfo[_poolId][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_poolId);
        uint256 pending = user.amount.mul(pool.accTalentPerShare).div(1e12).sub(
            user.rewardDebt
        );
        // take our 10% of the rewards
        pending = (pending.div(100)).mul(90);
        // send rewards to user
        safeTalentTransfer(msg.sender, pending);
        // burn _amount of gPhro
        veTalentToken.burnFrom(_amount, address(msg.sender));
        // send the _amount back to user
        safeTalentTransfer(msg.sender, _amount);
        // update struct
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accTalentPerShare).div(1e12);
        pool.depositSum = pool.depositSum.sub(_amount);

        // emit the event
        emit Withdraw(msg.sender, _poolId, _amount);
    }

    /// @dev transfers PHRO from contract if available and mints if not
    function safeTalentTransfer(address _to, uint256 _amount) internal {
        uint256 talentBal = talentToken.balanceOf(address(this));
        if (_amount <= talentBal) {
            talentToken.transfer(_to, _amount);
        } else {
            talentToken.mintTokensTo(_to, _amount);
        }
    }

    /// @dev transfers PHRO from contract if available and mints if not
    function safeVeTalentTransfer(address _to, uint256 _amount) internal {
        uint256 veTalentBal = veTalentToken.balanceOf(address(this));
        if (_amount <= veTalentBal) {
            veTalentToken.transfer(_to, veTalentBal);
        } else {
            veTalentToken.mintTokensTo(_to, _amount);
            // ** add event!!!
        }
    }

    /// @notice Pool Details Array[]
    /// @dev Returns the details of the pool requested
    /// @param _poolId The id of the pool
    /// @return Array of uint values for the Pool requested
    function poolDetails(uint256 _poolId)
        external
        view
        returns(uint256[4] memory)
    {
        PoolInfo storage pool = pools[_poolId];
        return [
            pool.allocationPoint,
            pool.lastRewardBlock,
            pool.depositSum,
            pool.accTalentPerShare
        ];
    }

    // /// @notice Staker Details Array
    // /// @dev Returns array of staker details uint256
    // /// @param _poolId The id of the pool
    // /// @param _staker The address of the staker
    // /// @return Array of uint256 of staker details
    // function stakerDetails(uint256 _poolId, address _staker)
    //     external
    //     view
    //     returns(uint256[2] memory)
    // {
    //     StakerInfo storage staker = stakerInfo[_poolId][_staker];
    //     return [
    //         staker.amount,
    //         staker.rewardDebt
    //     ];
    // }

    // /// @dev Withdraw without caring about rewards. EMERGENCY ONLY.
    // /// @param _poolId the id of the pool to withdraw from
    //     // nonReentrant
    // function emergencyWithdraw(uint256 _poolId)
    //     public
    // {
    //     PoolInfo storage pool = pools[_poolId];
    //     StakerInfo storage staker = stakerInfo[_poolId][msg.sender];

    //     uint256 amount = staker.amount;
    //     pool.depositSum = pool.depositSum.sub(amount);
    //     staker.amount = 0;
    //     staker.rewardDebt = 0;
    //     veTalentToken.burnFrom(msg.sender, amount);
    //     safeTalentTransfer(msg.sender, amount);

    //     emit Withdraw(msg.sender, _poolId, amount);
    // }

    // /// @dev sets a new bonus end block
    // /// @param _bonusEndBlock the new end block number for the bonus period
    // function setBonusEndBlock(uint256 _bonusEndBlock)
    //     public
    //     onlyOwner
    // {
    //     bonusEndBlock = _bonusEndBlock;
    // }

    // /// @dev sets a new reward fee in basis points
    // /// @param _rewardFee the fee we attach to the reward
    // function setRewardFee(uint256 _rewardFee)
    //     public
    //     onlyOwner
    // {
    //     require(_rewardFee > 0, "Must be greater than zero");
    //     rewardFee = _rewardFee;
    // }
}
