// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./IBEP20.sol";

contract Vesting is AccessControl, ReentrancyGuard {
    using SafeMath for uint256;
    address public operationWallet;
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant OPERATION_ROLE = keccak256("OPERATION_ROLE");
    uint256 public projectIndex;
    uint256 public poolIndex;
    mapping(uint256 => Pool) public pools;
    mapping(uint256 => Project) public projects;
    mapping(address => bool) public tokens;
    bool public requireCheckToken = false; // if true, one token is only one project

    event CreatePoolEvent(uint256 poolId);
    event UpdateVestingEvent(uint256 poolId);
    event CreateProjectEvent(uint256 project, string name, address tokenFund);
    event AddFundEvent(uint256 poolId, address user, uint256 fundAmount);
    event AddFundReleasedEvent(uint256 poolId, address user, uint256 fundAmount, uint256 releasedAmount);
    event RemoveFundEvent(uint256 poolId, address user);
    event ClaimFundEvent(
        uint256 poolId,
        address user,
        uint256 fundClaimed,
        address contractAddress
    );
    event DepositFundEvent(
        address contractAddress,
        address user,
        uint256 fundAmount
    );
    event WithdrawFundEvent(
        address contractAddress,
        address user,
        uint256 fundAmount
    );

    uint8 private constant VESTING_TYPE_MILESTONE_UNLOCK_FIRST = 1;
    uint8 private constant VESTING_TYPE_MILESTONE_CLIFF_FIRST = 2;
    uint8 private constant VESTING_TYPE_LINEAR_UNLOCK_FIRST = 3;
    uint8 private constant VESTING_TYPE_LINEAR_CLIFF_FIRST = 4;

    uint256 private constant ONE_HUNDRED_PERCENT_SCALED = 10000;
    uint256 private constant ONE_HUNDRED_YEARS_IN_S = 3153600000;

    enum PoolState {
        NEW,
        STARTING,
        PAUSE,
        SUCCESS
    }

    struct Project {
        uint256 id;
        IBEP20 tokenFund;
        string name;
        bool enableCreatePool;
        uint256[] poolIds;
    }

    struct Pool {
        IBEP20 tokenFund;
        uint256 id;
        uint256 projectId;
        string name;
        uint8 vestingType;
        uint256 tge;
        uint256 cliff;
        uint256 unlockPercent;
        uint256 linearVestingDuration;
        uint256[] milestoneTimes;
        uint256[] milestonePercents;
        mapping(address => uint256) funds;
        mapping(address => uint256) released;
        uint256 fundsTotal;
        uint256 fundsClaimed;
        PoolState state;
        bool enableChangeFund;
    }

    constructor(address _admin, address _treasury, address _manager, address _operationWallet) {
        _setupRole(DEFAULT_ADMIN_ROLE, _admin);
        _setupRole(TREASURY_ROLE, _treasury);
        _setupRole(MANAGER_ROLE, _manager);
        poolIndex = 400;
        projectIndex = 200;
        operationWallet = _operationWallet;
    }

    modifier onlyAdmin() {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Restricted to admins!"
        );
        _;
    }

    modifier onlyTreasury() {
        require(hasRole(TREASURY_ROLE, msg.sender), "Restricted to treasury!");
        _;
    }

    modifier onlyManager() {
        require(hasRole(MANAGER_ROLE, msg.sender), "Restricted to manager!");
        _;
    }

    modifier onlyOperation() {
        require(hasRole(OPERATION_ROLE, msg.sender), "Restricted to operation!");
        _;
    }

    function createProject(
        address _tokenFund,
        string memory _name
    ) external nonReentrant onlyAdmin {

        if(requireCheckToken) {
            require(!tokens[_tokenFund], "Token is existed in the other project");
        }

        uint256 index = projectIndex++;
        Project storage project = projects[index];
        project.id = index;
        project.name = _name;
        project.tokenFund = IBEP20(_tokenFund);
        project.enableCreatePool = true;
        tokens[_tokenFund] = true;
        emit CreateProjectEvent(index, _name, _tokenFund);
    }

    function createPool(
        address _tokenFund,
        string memory _name,
        uint256 _projectId,
        uint8 _vestingType,
        uint256 _tge,
        uint256 _cliff,
        uint256 _unlockPercent,
        uint256 _linearVestingDuration,
        uint256[] memory _milestoneTimes,
        uint256[] memory _milestonePercents
    ) external nonReentrant onlyAdmin {
        _validateSetup(
            _vestingType,
            _unlockPercent,
            _tge,
            _cliff,
            _linearVestingDuration,
            _milestoneTimes,
            _milestonePercents
        );

        require(
            _projectId > 0 && _projectId <= projectIndex,
            "Invalid project id"
        );
        Project storage project = projects[_projectId];
        require(address(project.tokenFund) == _tokenFund, "Invalid tokenFund");
        require(project.enableCreatePool == true, "enableCreatePool = false, can't create new pool");

        uint256 index = poolIndex++;
        Pool storage pool = pools[index];
        pool.id = index;
        pool.tokenFund = IBEP20(_tokenFund);
        pool.name = _name;
        pool.vestingType = _vestingType;
        pool.tge = _tge;
        pool.cliff = _cliff;
        pool.unlockPercent = _unlockPercent;
        pool.linearVestingDuration = _linearVestingDuration;
        pool.milestoneTimes = _milestoneTimes;
        pool.milestonePercents = _milestonePercents;
        pool.fundsTotal = 0;
        pool.fundsClaimed = 0;
        pool.enableChangeFund = true;
        pool.state = PoolState.NEW;

        project.poolIds.push(pool.id);

        pool.projectId = _projectId;

        emit CreatePoolEvent(index);
    }

    function start(uint256 _poolId) external nonReentrant onlyManager {
        Pool storage pool = pools[_poolId];
        require(
            pool.state == PoolState.NEW || pool.state == PoolState.PAUSE,
            "Invalid action"
        );
        pool.state = PoolState.STARTING;
    }

    function pause(uint256 _poolId) external nonReentrant onlyManager {
        Pool storage pool = pools[_poolId];
        require(pool.state != PoolState.PAUSE, "Invalid action");
        pool.state = PoolState.PAUSE;
    }

    function end(uint256 _poolId) external nonReentrant onlyManager {
        Pool storage pool = pools[_poolId];
        require(pool.state == PoolState.STARTING, "Invalid action");
        pool.state = PoolState.SUCCESS;
    }

    function updateVestingConfig(
        uint256 _poolId,
        uint8 _vestingType,
        uint256 _tge,
        uint256 _cliff,
        uint256 _unlockPercent,
        uint256 _linearVestingDuration,
        uint256[] memory _milestoneTimes,
        uint256[] memory _milestonePercents
    ) external nonReentrant onlyAdmin {
        _validateSetup(
            _vestingType,
            _unlockPercent,
            _tge,
            _cliff,
            _linearVestingDuration,
            _milestoneTimes,
            _milestonePercents
        );
        require(_poolId >= 0 && _poolId < poolIndex, "Invalid pool id");
        Pool storage pool = pools[_poolId];
        pool.vestingType = _vestingType;
        pool.tge = _tge;
        pool.cliff = _cliff;
        pool.unlockPercent = _unlockPercent;
        pool.linearVestingDuration = _linearVestingDuration;
        pool.milestoneTimes = _milestoneTimes;
        pool.milestonePercents = _milestonePercents;
        pool.state = PoolState.PAUSE;
        emit UpdateVestingEvent(_poolId);
    }


    function enableChangeFund(
        uint256 _poolId,
        bool _enable
    ) external nonReentrant onlyAdmin {
        Pool storage pool = pools[_poolId];
        pool.enableChangeFund = _enable;
    }

    function addFunds(
        uint256 _poolId,
        uint256[] memory _fundAmounts,
        address[] memory _users
    ) external nonReentrant onlyManager {
        require(
            _users.length == _fundAmounts.length,
            "Input arrays length mismatch"
        );
        Pool storage pool = pools[_poolId];
        Project storage project = projects[pool.projectId];
        if(project.enableCreatePool == true) {
            project.enableCreatePool == false;
        }
        require(pool.enableChangeFund == true, "enableChangeFund = false, can't add fund");
        for (uint256 i = 0; i < _users.length; i++) {

            address user = _users[i];
            uint256 fundAmount = _fundAmounts[i];
            uint256 oldFund = pool.funds[user];
            if (oldFund > 0) {
                pool.fundsTotal = pool.fundsTotal.add(fundAmount);
                pool.funds[user] = pool.funds[user].add(fundAmount);
            } else {
                pool.fundsTotal = pool.fundsTotal.add(fundAmount);
                pool.funds[user] = pool.funds[user].add(fundAmount);
                pool.released[user] = 0;
            }

            emit AddFundEvent(_poolId, user, fundAmount);
        }
    }

    function addFundsWithReleased(
        uint256 _poolId,
        uint256[] memory _fundAmounts,
        address[] memory _users,
        uint256[] memory _releaseds
    ) external nonReentrant onlyManager {
        require(
            _users.length == _fundAmounts.length &&
                _users.length == _releaseds.length,
            "Input arrays length mismatch"
        );
        Pool storage pool = pools[_poolId];
        Project storage project = projects[pool.projectId];
        if(project.enableCreatePool == true) {
            project.enableCreatePool == false;
        }
        require(pool.enableChangeFund == true, "enableChangeFund = false, can't add fund");
        for (uint256 i = 0; i < _users.length; i++) {

            address user = _users[i];
            uint256 fundAmount = _fundAmounts[i];
            uint256 releasedAmount = _releaseds[i];
            uint256 oldFund = pool.funds[user];
            if (oldFund > 0) {
                pool.fundsTotal = pool.fundsTotal.add(fundAmount);
                pool.funds[user] = pool.funds[user].add(fundAmount);
                pool.released[user] = pool.released[user].add(releasedAmount);
            } else {
                pool.fundsTotal = pool.fundsTotal.add(fundAmount);
                pool.funds[user] = pool.funds[user].add(fundAmount);
                pool.released[user] = releasedAmount;
            }

            emit AddFundReleasedEvent(_poolId, user, fundAmount, releasedAmount);
        }
    }

    function removeFunds(
        uint256 _poolId,
        address[] memory _users
    ) external nonReentrant onlyManager {
        Pool storage pool = pools[_poolId];
        require(pool.enableChangeFund == true, "enableChangeFund = false");
        for (uint256 i = 0; i < _users.length; i++) {
            address user = _users[i];
            uint256 oldFund = pool.funds[user];
            if (oldFund > 0) {
                pool.funds[user] = 0;
                pool.released[user] = 0;
                pool.fundsTotal = pool.fundsTotal.sub(oldFund);

                emit RemoveFundEvent(_poolId, user);
            }
        }
    }

    function claimFund(uint256 _poolId) external nonReentrant {
        _validateClaimFund(_poolId);
        _claim(_poolId);
    }

    function claimAll(uint256 _projectId) external nonReentrant {
        require(
            _projectId > 0 && _projectId <= projectIndex,
            "Invalid project id"
        );
        //get pools user joined in project
        for (uint256 i = 0; i < projects[_projectId].poolIds.length; i++) {
            uint256 poolId = projects[_projectId].poolIds[i];
            //validate
            if (checkClaimablePool(poolId, _msgSender())) {
                _claim(poolId);
            }
        }
    }

    function _claim(uint256 _poolId) internal {
        Pool storage pool = pools[_poolId];
        uint256 _now = block.timestamp;
        require(_now >= pool.tge, "Invalid Time");
        uint256 claimPercent = computeClaimPercent(_poolId, _now);
        require(claimPercent > 0, "Not enough unlock token to claim");

        uint256 claimTotal = (pool.funds[_msgSender()].mul(claimPercent)).div(
            ONE_HUNDRED_PERCENT_SCALED
        );
        require(
            claimTotal > pool.released[_msgSender()],
            "Not enough unlock token to claim"
        );
        uint256 claimRemain = claimTotal.sub(pool.released[_msgSender()]);

        pool.tokenFund.transfer(_msgSender(), claimRemain);

        pool.released[_msgSender()] = pool.released[_msgSender()].add(
            claimRemain
        );
        pool.fundsClaimed = pool.fundsClaimed.add(claimRemain);

        emit ClaimFundEvent(_poolId, _msgSender(), claimRemain, address(this));
    }

    function depositFund(
        uint256 _poolId,
        uint256 _fundAmount
    ) external nonReentrant onlyTreasury {
        require(_fundAmount > 0, "Amount must be greater than zero");

        Pool storage pool = pools[_poolId];

        require(
            pool.tokenFund.balanceOf(_msgSender()) >= _fundAmount,
            "Error: not enough Token"
        );

        pool.tokenFund.transferFrom(_msgSender(), address(this), _fundAmount);

        emit DepositFundEvent(address(this), _msgSender(), _fundAmount);
    }

    function withdrawFund(
        uint256 _poolId,
        uint256 _fundAmount
    ) external nonReentrant onlyTreasury {
        require(_fundAmount > 0, "Amount must be greater than zero");
        Pool storage pool = pools[_poolId];
        require(
            pool.tokenFund.balanceOf(address(this)) >= _fundAmount,
            "Fund insufficient!"
        );

        pool.tokenFund.transfer(operationWallet, _fundAmount);

        emit WithdrawFundEvent(address(this), operationWallet, _fundAmount);
    }

    function changeOperationWallet(address _newOperationWallet) external nonReentrant onlyOperation {
        require(_newOperationWallet != address(0), "Invalid address");
        require(_newOperationWallet != operationWallet, "Same address");
        require(_msgSender() == operationWallet, "Only the old operationWallet owner can change");
        operationWallet = _newOperationWallet;
    }

    function enableRequireCheckToken() external nonReentrant onlyAdmin {
        requireCheckToken = true;
    }

    function disableRequireCheckToken() external nonReentrant onlyOperation {
        require(_msgSender() == operationWallet, "Only operationWallet owner can disable requireCheckToken");
        requireCheckToken = false;
    }

    function computeClaimPercent(
        uint256 _poolId,
        uint256 _now
    ) public view returns (uint256) {
        Pool storage pool = pools[_poolId];
        uint256[] memory milestoneTimes = pool.milestoneTimes;
        uint256[] memory milestonePercents = pool.milestonePercents;
        uint256 totalPercent = 0;
        uint256 tge = pool.tge;
        if (pool.vestingType == VESTING_TYPE_MILESTONE_CLIFF_FIRST) {
            if (_now >= tge.add(pool.cliff)) {
                totalPercent = totalPercent.add(pool.unlockPercent);
                for (uint i = 0; i < milestoneTimes.length; i++) {
                    uint256 milestoneTime = milestoneTimes[i];
                    uint256 milestonePercent = milestonePercents[i];
                    if (_now >= milestoneTime) {
                        totalPercent = totalPercent.add(milestonePercent);
                    }
                }
            }
        } else if (pool.vestingType == VESTING_TYPE_MILESTONE_UNLOCK_FIRST) {
            if (_now >= tge) {
                totalPercent = totalPercent.add(pool.unlockPercent);
                if (_now >= tge.add(pool.cliff)) {
                    for (uint i = 0; i < milestoneTimes.length; i++) {
                        uint256 milestoneTime = milestoneTimes[i];
                        uint256 milestonePercent = milestonePercents[i];
                        if (_now >= milestoneTime) {
                            totalPercent = totalPercent.add(milestonePercent);
                        }
                    }
                }
            }
        } else if (pool.vestingType == VESTING_TYPE_LINEAR_UNLOCK_FIRST) {
            if (_now >= tge) {
                totalPercent = totalPercent.add(pool.unlockPercent);
                if (_now >= tge.add(pool.cliff)) {
                    uint256 delta = _now.sub(tge).sub(pool.cliff);
                    totalPercent = totalPercent.add(
                        delta
                            .mul(
                                ONE_HUNDRED_PERCENT_SCALED.sub(
                                    pool.unlockPercent
                                )
                            )
                            .div(pool.linearVestingDuration)
                    );
                }
            }
        } else if (pool.vestingType == VESTING_TYPE_LINEAR_CLIFF_FIRST) {
            if (_now >= tge.add(pool.cliff)) {
                totalPercent = totalPercent.add(pool.unlockPercent);
                uint256 delta = _now.sub(tge).sub(pool.cliff);
                totalPercent = totalPercent.add(
                    delta
                        .mul(ONE_HUNDRED_PERCENT_SCALED.sub(pool.unlockPercent))
                        .div(pool.linearVestingDuration)
                );
            }
        }
        return
            (totalPercent < ONE_HUNDRED_PERCENT_SCALED)
                ? totalPercent
                : ONE_HUNDRED_PERCENT_SCALED;
    }

    function getFundByUser(
        uint256 _poolId,
        address _user
    ) public view returns (uint256, uint256) {
        return (pools[_poolId].funds[_user], pools[_poolId].released[_user]);
    }

    function getInfoUserReward(
        uint256 _poolId
    ) public view returns (uint256, uint256) {
        Pool storage pool = pools[_poolId];
        uint256 tokenTotal = pool.fundsTotal;
        uint256 claimedTotal = pool.fundsClaimed;

        return (tokenTotal, claimedTotal);
    }

    function checkClaimablePool(
        uint256 _poolId,
        address _user
    ) public view returns (bool) {
        Pool storage pool = pools[_poolId];
        if (pool.state != PoolState.STARTING) return false;
        uint256 _now = block.timestamp;
        if (_now < pool.tge) return false;
        if (pool.funds[_user] <= 0) return false;
        if (pool.funds[_user] <= pool.released[_user]) return false;

        uint256 claimPercent = computeClaimPercent(_poolId, _now);
        if (claimPercent <= 0) return false;
        uint256 claimTotal = (pool.funds[_user].mul(claimPercent)).div(
            ONE_HUNDRED_PERCENT_SCALED
        );
        if (claimTotal <= pool.released[_user]) return false;
        return true;
    }

    function checkClaimableProject(
        uint256 _projectId,
        address _user
    ) public view returns (bool) {
        require(
            _projectId > 0 && _projectId <= projectIndex,
            "Invalid project id"
        );
        for (uint256 i = 0; i < projects[_projectId].poolIds.length; i++) {
            if (checkClaimablePool(projects[_projectId].poolIds[i], _user)) {
                return true;
            }
        }
        return false;
    }

    function getPool(
        uint256 _poolId
    )
        public
        view
        returns (
            address,
            string memory,
            uint8,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256[] memory,
            uint256[] memory,
            uint256,
            uint256,
            PoolState
        )
    {
        Pool storage pool = pools[_poolId];
        return (
            address(pool.tokenFund),
            pool.name,
            pool.vestingType,
            pool.tge,
            pool.cliff,
            pool.unlockPercent,
            pool.linearVestingDuration,
            pool.milestoneTimes,
            pool.milestonePercents,
            pool.fundsTotal,
            pool.fundsClaimed,
            pool.state
        );
    }

    function _validateClaimFund(uint256 _poolId) private view {
        Pool storage pool = pools[_poolId];
        require(pool.state == PoolState.STARTING, "Invalid action");
        require(
            pool.funds[_msgSender()] > 0,
            "Amount must be greater than zero"
        );
        require(
            pool.funds[_msgSender()] > pool.released[_msgSender()],
            "All money has been claimed"
        );
    }

    function _validateSetup(
        uint8 _vestingType,
        uint256 _unlockPercent,
        uint256 _tge,
        uint256 _cliff,
        uint256 _linearVestingDuration,
        uint256[] memory _milestoneTimes,
        uint256[] memory _milestonePercents
    ) private {
        require(
            _vestingType >= VESTING_TYPE_MILESTONE_UNLOCK_FIRST &&
                _vestingType <= VESTING_TYPE_LINEAR_CLIFF_FIRST,
            "Invalid action"
        );
        require(
            _unlockPercent >= 0 &&
                _unlockPercent <= ONE_HUNDRED_PERCENT_SCALED &&
                _cliff >= 0,
            "Invalid input parameter"
        );
        if (
            _vestingType == VESTING_TYPE_MILESTONE_CLIFF_FIRST ||
            _vestingType == VESTING_TYPE_MILESTONE_UNLOCK_FIRST
        ) {
            require(
                _milestoneTimes.length == _milestonePercents.length &&
                    _milestoneTimes.length >= 0 &&
                    _linearVestingDuration >= 0,
                "Invalid vesting parameter"
            );
            uint256 total = _unlockPercent;
            uint256 curTime = 0;
            for (uint i = 0; i < _milestoneTimes.length; i++) {
                total = total + _milestonePercents[i];
                uint256 tmpTime = _milestoneTimes[i];
                require(
                    tmpTime >= _tge + _cliff && tmpTime > curTime,
                    "Invalid input parameter"
                );
                curTime = tmpTime;
            }
            require(
                total == ONE_HUNDRED_PERCENT_SCALED,
                "Invalid vesting parameter"
            );
        } else {
            require(
                _milestoneTimes.length == 0 &&
                    _milestonePercents.length == 0 &&
                    (_linearVestingDuration > 0 &&
                        _linearVestingDuration <= ONE_HUNDRED_YEARS_IN_S),
                "Invalid vesting parameter"
            );
        }
    }
}
