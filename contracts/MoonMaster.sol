// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./MoonLounge.sol";
import "./DoubleMoonCat.sol";
import "./libs/IMoonReferral.sol";

// MoonMaster is the master of DMC AND MoonLounge. He can make DMC and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once DoubleMoonCat is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MoonMaster is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 bonusDebt; // Last block that user exec something to the pool.
        //
        // We do some fancy math here. Basically, any point in time, the amount of DMCs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accTokenPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accTokenPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. DMCs to distribute per block.
        uint256 lastRewardBlock; // Last block number that DMCs distribution occurs.
        uint256 accTokenPerShare; // Accumulated DMCs per share, times 1e12. See below.
        uint256 accTokenPerShareTilBonusEnd; // Accumated ALPACAs per share until Bonus End.
    }

    // The DoubleMoonCat TOKEN!
    DoubleMoonCat public token;
    // The DoubleMoonCat SPLIT TOKEN!
    MoonLounge public lounge;
    // The Fee TOKEN!
    IBEP20 public feeToken;
    // Dev address.
    address public devAddress;
    // DoubleMoonCat tokens created per block.
    uint256 public tokenPerBlock;
    // Bonus muliplier for early dmc makers.
    uint256 public bonusMultiplier;
    // Block number when bonus ALPACA period ends.
    uint256 public bonusEndBlock;
    // Bonus lock-up in BPS
    uint256 public bonusLockUpBps;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when DoubleMoonCat mining starts.
    uint256 public startBlock;

    // Moon referral contract address.
    IMoonReferral public moonReferral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 100;
    // Max referral commission rate: 10%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 1000;

    // Fee amount.
    uint256 public feeAmount;
    // Waive fee amount
    uint256 public waiveFeeAmount;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event EmissionRateUpdated(
        address indexed user,
        uint256 previousAmount,
        uint256 newAmount
    );
    event ReferralCommissionPaid(
        address indexed user,
        address indexed referrer,
        uint256 commissionAmount
    );

    constructor(
        DoubleMoonCat _token,
        MoonLounge _moonLounge,
        IBEP20 _feeToken,
        uint256 _feeAmount,
        uint256 _waiveFeeAmount,
        address _devAddress,
        uint256 _tokenPerBlock,
        uint256 _startBlock,
        uint256 _bonusLockupBps,
        uint256 _bonusEndBlock,
        uint256 _multiplier
    ) public {
        token = _token;
        lounge = _moonLounge;
        feeToken = _feeToken;
        feeAmount = _feeAmount;
        waiveFeeAmount = _waiveFeeAmount;
        devAddress = _devAddress;
        tokenPerBlock = _tokenPerBlock;
        startBlock = _startBlock;
        bonusLockUpBps = _bonusLockupBps;
        bonusEndBlock = _bonusEndBlock;
        bonusMultiplier = _multiplier;

        // staking pool
        poolInfo.push(
            PoolInfo({
                lpToken: _token,
                allocPoint: 1000,
                lastRewardBlock: startBlock,
                accTokenPerShare: 0,
                accTokenPerShareTilBonusEnd: 0
            })
        );

        totalAllocPoint = 1000;
    }

    modifier validatePool(uint256 _pid) {
        require(_pid < poolInfo.length, "validatePool: pool exists?");
        _;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function manualMint(address _to, uint256 _amount) external onlyOwner {
        token.manualMint(_to, _amount);
    }

    // Detects whether the given pool already exists
    function checkPoolDuplicate(IBEP20 _lpToken) public view {
        uint256 length = poolInfo.length;
        for (uint256 _pid = 0; _pid < length; _pid++) {
            require(poolInfo[_pid].lpToken != _lpToken, "add: existing pool");
        }
    }

    // Set Bonus params. bonus will start to accu on the next block that this function executed
    function setBonus(
        uint256 _bonusMultiplier,
        uint256 _bonusEndBlock,
        uint256 _bonusLockUpBps
    ) external onlyOwner {
        require(_bonusEndBlock > block.number, "setBonus: bad bonusEndBlock");
        require(_bonusMultiplier > 1, "setBonus: bad bonusMultiplier");
        bonusMultiplier = _bonusMultiplier;
        bonusEndBlock = _bonusEndBlock;
        bonusLockUpBps = _bonusLockUpBps;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        IBEP20 _lpToken,
        bool _withUpdate
    ) public onlyOwner {
        require(address(_lpToken) != address(0), "add: cannot add zero address");

        if (_withUpdate) {
            massUpdatePools();
        }
        checkPoolDuplicate(_lpToken);
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accTokenPerShare: 0,
                accTokenPerShareTilBonusEnd: 0
            })
        );
        updateStakingPool();
    }

    // Update the given pool's DoubleMoonCat allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) external onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
            updateStakingPool();
        }
    }

    function updateStakingPool() internal {
        uint256 length = poolInfo.length;
        uint256 points = 0;
        for (uint256 pid = 1; pid < length; ++pid) {
            points = points.add(poolInfo[pid].allocPoint);
        }
        if (points != 0) {
            points = points.div(3);
            totalAllocPoint = totalAllocPoint.sub(poolInfo[0].allocPoint).add(
                points
            );
            poolInfo[0].allocPoint = points;
        }
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _lastRewardBlock, uint256 _currentBlock)
        public
        view
        returns (uint256)
    {
        if (_currentBlock <= bonusEndBlock) {
            return _currentBlock.sub(_lastRewardBlock).mul(bonusMultiplier);
        }
        if (_lastRewardBlock >= bonusEndBlock) {
            return _currentBlock.sub(_lastRewardBlock);
        }
        // This is the case where bonusEndBlock is in the middle of _lastRewardBlock and _currentBlock block.
        return bonusEndBlock.sub(_lastRewardBlock).mul(bonusMultiplier).add(_currentBlock.sub(bonusEndBlock));
    }

    // View function to see pending DMCs on frontend.
    function pendingReward(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accTokenPerShare = pool.accTokenPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier =
                getMultiplier(pool.lastRewardBlock, block.number);
            uint256 tokenReward =
                multiplier.mul(tokenPerBlock).mul(pool.allocPoint).div(
                    totalAllocPoint
                );
            accTokenPerShare = accTokenPerShare.add(
                tokenReward.mul(1e12).div(lpSupply)
            );
        }
        return user.amount.mul(accTokenPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 tokenReward =
            multiplier.mul(tokenPerBlock).mul(pool.allocPoint).div(
                totalAllocPoint
            );
        uint256 commissionAmount = tokenReward.mul(referralCommissionRate).div(10000);
        token.mint(devAddress, tokenReward.div(10));
        token.mint(address(lounge), tokenReward.add(commissionAmount));
        pool.accTokenPerShare = pool.accTokenPerShare.add(
            tokenReward.mul(1e12).div(lpSupply)
        );

        if (block.number <= bonusEndBlock) {
            token.lock(devAddress, tokenReward.mul(bonusLockUpBps).div(100000));
            pool.accTokenPerShareTilBonusEnd = pool.accTokenPerShare;
        }
        if (block.number > bonusEndBlock && pool.lastRewardBlock < bonusEndBlock) {
            uint256 alpacaBonusPortion = bonusEndBlock.sub(pool.lastRewardBlock).mul(bonusMultiplier).mul(tokenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            token.lock(devAddress, alpacaBonusPortion.mul(bonusLockUpBps).div(100000));
            pool.accTokenPerShareTilBonusEnd = pool.accTokenPerShareTilBonusEnd.add(alpacaBonusPortion.mul(1e12).div(lpSupply));
        }
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MoonMaster for DoubleMoonCat allocation.
    function deposit(
        uint256 _pid,
        uint256 _amount,
        address _referrer
    ) external validatePool(_pid) nonReentrant {
        require(_pid != 0, "deposit: cannot deposit zero pool");
        require(feeToken.balanceOf(msg.sender) >= feeAmount, "deposit: no fee");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            // auto claim reward
            _harvest(msg.sender, _pid);
        }
        if (_amount > 0) {
            if (address(moonReferral) != address(0) &&
                _referrer != address(0) &&
                _referrer != msg.sender) {
                moonReferral.recordReferral(msg.sender, _referrer);
            }

            safeTransferFee(devAddress, feeAmount);
            pool.lpToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                _amount
            );
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e12);
        user.bonusDebt = user.amount.mul(pool.accTokenPerShareTilBonusEnd).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MoonMaster.
    function withdraw(uint256 _pid, uint256 _amount) external validatePool(_pid) nonReentrant {
        require(_pid != 0, "withdraw: cannot withdraw zero pool");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);
        _harvest(msg.sender, _pid);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e12);
        user.bonusDebt = user.amount.mul(pool.accTokenPerShareTilBonusEnd).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Harvest DMCs earn from the pool.
    function harvest(uint256 _pid) external nonReentrant {
        require(_pid != 0, "harvest: cannot harvest zero pool");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        _harvest(msg.sender, _pid);
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e12);
        user.bonusDebt = user.amount.mul(pool.accTokenPerShareTilBonusEnd).div(1e12);
    }

    function _harvest(address _to, uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_to];
        require(user.amount > 0, "_harvest: nothing to harvest");
        uint256 pending = user.amount.mul(pool.accTokenPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            uint256 bonus = user.amount.mul(pool.accTokenPerShareTilBonusEnd).div(1e12).sub(user.bonusDebt);
            safeTokenTransfer(_to, pending);
            payReferralCommission(msg.sender, pending);
            token.lock(_to, bonus.mul(bonusLockUpBps).div(10000));
        }
    }

    // Stake DoubleMoonCat tokens to MoonMaster
    function enterStaking(uint256 _amount) external nonReentrant {
        require(feeToken.balanceOf(msg.sender) >= feeAmount, "enterStaking: no fee");

        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        updatePool(0);
        if (user.amount > 0) {
            _harvest(msg.sender, 0);
        }
        if (_amount > 0) {
            safeTransferFee(devAddress, feeAmount);
            pool.lpToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                _amount
            );
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e12);
        user.bonusDebt = user.amount.mul(pool.accTokenPerShareTilBonusEnd).div(1e12);

        lounge.mint(msg.sender, _amount);
        emit Deposit(msg.sender, 0, _amount);
    }

    // Withdraw DoubleMoonCat tokens from STAKING.
    function leaveStaking(uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        require(user.amount >= _amount, "leaveStaking: withdraw: not good");
        updatePool(0);
        _harvest(msg.sender, 0);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e12);
        user.bonusDebt = user.amount.mul(pool.accTokenPerShareTilBonusEnd).div(1e12);

        lounge.burn(msg.sender, _amount);
        emit Withdraw(msg.sender, 0, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    function safeTransferFee(address _to, uint256 _amount) internal {
        if (feeToken.balanceOf(msg.sender) < waiveFeeAmount && _amount > 0) {
            feeToken.safeTransferFrom(msg.sender, _to, _amount);
        }
    }

    // Safe token transfer function, just in case if rounding error causes pool to not have enough DMCs.
    function safeTokenTransfer(address _to, uint256 _amount) internal {
        lounge.safeTokenTransfer(_to, _amount);
    }

    // Update emission rate
    function updateEmissionRate(uint256 _tokenPerBlock) external onlyOwner {
        massUpdatePools();
        emit EmissionRateUpdated(msg.sender, tokenPerBlock, _tokenPerBlock);
        tokenPerBlock = _tokenPerBlock;
    }

    function setMoonReferral(IMoonReferral _moonReferral) external onlyOwner {
        moonReferral = _moonReferral;
    }

    // Update referral commission rate by the owner
    function setReferralCommissionRate(uint16 _referralCommissionRate)
        external
        onlyOwner
    {
        require(
            _referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE,
            "setReferralCommissionRate: invalid referral commission rate basis points"
        );
        referralCommissionRate = _referralCommissionRate;
    }

    // Pay referral commission to the referrer who referred this user.
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(moonReferral) != address(0) && referralCommissionRate > 0) {
            address referrer = moonReferral.getReferrer(_user);
            uint256 commissionAmount =
                _pending.mul(referralCommissionRate).div(10000);

            if (referrer != address(0) && commissionAmount > 0) {
                safeTokenTransfer(referrer, commissionAmount);
                moonReferral.recordReferralCommission(
                    referrer,
                    commissionAmount
                );
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
            }
        }
    }

    // Update fee token.
    function setFeeToken(IBEP20 _feeToken) external onlyOwner {
		feeToken = _feeToken;
	}

    // Update fee amount and waive fee amount.
    function setFeeAmount(uint256 _feeAmount, uint256 _waiveFeeAmount) external onlyOwner {
		feeAmount = _feeAmount;
		waiveFeeAmount = _waiveFeeAmount;
	}

    // Update dev address by the previous dev.
    function setDevAddress(address _devAddress) external {
        require(msg.sender == devAddress, "setDevAddress: dev: wut?");
        require(_devAddress != address(0), "setDevAddress: ZERO");
        devAddress = _devAddress;
    }
}
