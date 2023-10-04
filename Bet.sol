// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SportsPrediction is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;

    address public adminAddress; // address of the admin
    address public operatorAddress; // address of the operator, will handle match result, game status etc.
    address public tokenAddress; // address of the token

    uint256 public bufferSeconds = 30; // number of seconds for valid execution of a prediction match

    uint256 public minBetAmount = 10000000000000000; // minimum betting amount (denominated in wei)
    uint256 public maxBetAmount = 1000000000000000000; // maximum betting amount (denominated in wei)
    uint256 public treasuryFee = 1000; // treasury rate (e.g. 200 = 2%, 150 = 1.50%)
    uint256 public treasuryAmount; // treasury amount that was not claimed

    uint256 public constant MAX_TREASURY_FEE = 1000; // 10%

    mapping(uint256 => mapping(address => BetInfo)) public ledger;
    mapping(uint256 => Match) public matches;
    mapping(address => uint256[]) public userMatches;
    mapping(address => Position) public userRewards;

    enum Position {
        Home,
        Draw,
        Away
    }

    struct Match {
        uint256 fixture;
        uint256 startTimestamp;
        uint256 lockTimestamp;
        uint256 closeTimestamp;
        uint256 matchResult;
        bool finished;
        uint256 totalAmount;
        uint256 homeAmount;
        uint256 drawAmount;
        uint256 awayAmount;
        uint256 rewardBaseCalAmount;
        uint256 rewardAmount;
    }

    struct MatchInfo {
        uint256 fixture;
        bool finished;
        uint8 result;
    }

    struct BetInfo {
        Position position;
        uint256 amount;
        bool claimed; // default false
    }

    event BetHome(address indexed sender, uint256 indexed fixture, uint256 amount);
    event BetDraw(address indexed sender, uint256 indexed fixture, uint256 amount);
    event BetAway(address indexed sender, uint256 indexed fixture, uint256 amount);
    event Claim(address indexed sender, uint256 indexed fixture, uint256 amount);
    event EndMatch(uint256 indexed fixture, uint256 indexed matchResult, bool finished);
    event LockMatch(uint256 indexed fixture, uint256 indexed matchId, int256 price);


    event NewAdminAddress(address admin);
    event NewBuffer(uint256 bufferSeconds);
    event NewMinBetAmount(uint256 changeTime, uint256 minBetAmount);
    event NewMaxBetAmount(uint256 changeTime, uint256 maxBetAmount);
    event NewTreasuryFee(uint256 changeTime, uint256 treasuryFee);
    event NewOperatorAddress(address operator);

    event RewardsCalculated(
        uint256 indexed fixture,
        uint256 rewardBaseCalAmount,
        uint256 rewardAmount,
        uint256 treasuryAmount
    );

    event StartMatch(uint256 indexed fixture);
    event TokenRecovery(address indexed token, uint256 amount);
    event TreasuryClaim(uint256 amount);
    event Pause(uint256 timestamp);
    event UnPause(uint256 timestamp);

    modifier onlyAdmin() {
        require(msg.sender == adminAddress, "Not admin");
        _;
    }

    modifier onlyAdminOrOperator() {
        require(msg.sender == adminAddress || msg.sender == operatorAddress, "Not operator/admin");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operatorAddress, "Not operator");
        _;
    }

    modifier notContract() {
        require(!_isContract(msg.sender), "Contract not allowed");
        require(msg.sender == tx.origin, "Proxy contract not allowed");
        _;
    }

    /**
     * @notice Constructor
     * @param _adminAddress: admin address
     * @param _operatorAddress: operator address
     */
    constructor(
        address _adminAddress,
        address _operatorAddress,
        address _tokenAddress
    ) {
        adminAddress = _adminAddress;
        operatorAddress = _operatorAddress;
        tokenAddress = _tokenAddress;
    }

    /**
     * @notice Bet Home position
     * @param fixture: fixture
     */
    function betHome(uint256 fixture, uint256 _amount) external whenNotPaused nonReentrant notContract {

        require(_betTable(fixture), "Match not bettable");
        require(_amount >= minBetAmount, "Bet amount must be greater than minBetAmount");
        require(_amount <= maxBetAmount, "Bet amount must be smaller than maxBetAmount");
        require(ledger[fixture][msg.sender].amount == 0 || ledger[fixture][msg.sender].position == Position.Home, "You can not bet to this match");
        // Update match data

        Match storage mm = matches[fixture];
        mm.totalAmount = mm.totalAmount + _amount;
        mm.homeAmount = mm.homeAmount + _amount;

        // Update user data
        BetInfo storage betInfo = ledger[fixture][msg.sender];
        betInfo.position = Position.Home;
        betInfo.amount = _amount;
        userMatches[msg.sender].push(fixture);

        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), _amount);

        emit BetHome(msg.sender, fixture, _amount);
    }

    /**
     * @notice Bet Draw position
     * @param fixture: fixture
     */
    function betDraw(uint256 fixture, uint256 _amount) external whenNotPaused nonReentrant notContract {

        require(_betTable(fixture), "Match not bettable");
        require(_amount >= minBetAmount, "Bet amount must be greater than minBetAmount");
        require(_amount <= maxBetAmount, "Bet amount must be smaller than maxBetAmount");
        require(ledger[fixture][msg.sender].amount == 0 || ledger[fixture][msg.sender].position == Position.Draw, "You can not bet to this match");

        // Update match data
        Match storage mm = matches[fixture];
        mm.totalAmount = mm.totalAmount + _amount;
        mm.drawAmount = mm.drawAmount + _amount;

        // Update user data
        BetInfo storage betInfo = ledger[fixture][msg.sender];
        betInfo.position = Position.Draw;
        betInfo.amount = _amount;
        userMatches[msg.sender].push(fixture);

        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), _amount);

        emit BetDraw(msg.sender, fixture, _amount);
    }

    /**
     * @notice Bet Away position
     * @param fixture: fixture
     */
    function betAway(uint256 fixture, uint256 _amount) external whenNotPaused nonReentrant notContract {

        require(_betTable(fixture), "Match not bettable");
        require(_amount >= minBetAmount, "Bet amount must be greater than minBetAmount");
        require(_amount <= maxBetAmount, "Bet amount must be smaller than maxBetAmount");
        require(ledger[fixture][msg.sender].amount == 0 || ledger[fixture][msg.sender].position == Position.Away, "You can not bet to this match");

        // Update match data
        Match storage mm = matches[fixture];
        mm.totalAmount = mm.totalAmount + _amount;
        mm.awayAmount = mm.awayAmount + _amount;

        // Update user data
        BetInfo storage betInfo = ledger[fixture][msg.sender];
        betInfo.position = Position.Away;
        betInfo.amount = _amount;
        userMatches[msg.sender].push(fixture);

        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), _amount);

        emit BetAway(msg.sender, fixture, _amount);
    }

    /**
     * @notice Claim reward for an array of fixtures
     * @param fixtures: array of fixture
     */
    function claim(uint256[] calldata fixtures) external nonReentrant notContract {
        uint256 reward;
        // Initializes reward

        for (uint256 i = 0; i < fixtures.length; i++) {
            require(matches[fixtures[i]].startTimestamp != 0, "Match has not started");
            require(block.timestamp > matches[fixtures[i]].closeTimestamp, "Match has not ended");

            uint256 addedReward = 0;

            // Match valid, claim rewards
            require(claimable(fixtures[i], msg.sender), "Not eligible for claim");
            Match memory mm = matches[fixtures[i]];
            addedReward = (ledger[fixtures[i]][msg.sender].amount * mm.rewardAmount) / mm.rewardBaseCalAmount;

            ledger[fixtures[i]][msg.sender].claimed = true;
            reward += addedReward;

            emit Claim(msg.sender, fixtures[i], addedReward);
        }

        if (reward > 0) {
            _safeTransferToken(address(msg.sender), reward);
        }
    }

    /**
     * @notice called by the admin to pause, triggers stopped state
     * @dev Callable by admin or operator
     */
    function pause() external whenNotPaused onlyAdminOrOperator {
        _pause();
        emit Pause(block.timestamp);
    }

    /**
     * @notice Claim all rewards in treasury
     * @dev Callable by admin
     */
    function claimTreasury() external nonReentrant onlyAdmin {
        uint256 currentTreasuryAmount = treasuryAmount;
        _safeTransferToken(adminAddress, currentTreasuryAmount);
        treasuryAmount = 0;

        emit TreasuryClaim(currentTreasuryAmount);
    }

    /**
     * @notice called by the admin to unpause, returns to normal state
     * Reset genesis state. Once paused, the matches would need to be kickstarted by genesis
     */
    function unpause() external whenPaused onlyAdmin {
        _unpause();

        emit UnPause(block.timestamp);
    }

    /**
     * @notice Set buffer (in seconds)
     * @dev Callable by admin
     */
    function setBuffer(uint256 _bufferSeconds) external whenPaused onlyAdmin {
        bufferSeconds = _bufferSeconds;

        emit NewBuffer(_bufferSeconds);
    }

    /**
     * @notice Set minBetAmount
     * @dev Callable by admin
     */
    function setMinBetAmount(uint256 _minBetAmount) external whenPaused onlyAdmin {
        require(_minBetAmount != 0, "Must be superior to 0");
        minBetAmount = _minBetAmount;

        emit NewMinBetAmount(block.timestamp, minBetAmount);
    }

    /**
     * @notice Set minBetAmount
     * @dev Callable by admin
     */
    function setMaxBetAmount(uint256 _maxBetAmount) external whenPaused onlyAdmin {
        require(_maxBetAmount != 0, "Must be superior to 0");
        maxBetAmount = _maxBetAmount;

        emit NewMaxBetAmount(block.timestamp, minBetAmount);
    }

    /**
     * @notice Set operator address
     * @dev Callable by admin
     */
    function setOperator(address _operatorAddress) external onlyAdmin {
        require(_operatorAddress != address(0), "Cannot be zero address");
        operatorAddress = _operatorAddress;

        emit NewOperatorAddress(_operatorAddress);
    }

    /**
     * @notice Set treasury fee
     * @dev Callable by admin
     */
    function setTreasuryFee(uint256 _treasuryFee) external whenPaused onlyAdmin {
        require(_treasuryFee <= MAX_TREASURY_FEE, "Treasury fee too high");
        treasuryFee = _treasuryFee;

        emit NewTreasuryFee(block.timestamp, treasuryFee);
    }

    /**
     * @notice It allows the owner to recover tokens sent to the contract by mistake
     * @param _token: token address
     * @param _amount: token amount
     * @dev Callable by owner
     */
    function recoverToken(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).safeTransfer(address(msg.sender), _amount);

        emit TokenRecovery(_token, _amount);
    }

    /**
     * @notice Set admin address
     * @dev Callable by owner
     */
    function setAdmin(address _adminAddress) external onlyOwner {
        require(_adminAddress != address(0), "Cannot be zero address");
        adminAddress = _adminAddress;

        emit NewAdminAddress(_adminAddress);
    }

    /**
     * @notice Returns match fixtures and bet information for a user that has participated
     * @param user: user address
     * @param cursor: cursor
     * @param size: size
     */
    function getUserMatches(
        address user,
        uint256 cursor,
        uint256 size
    ) external view returns (uint256[] memory, BetInfo[] memory, bool[] memory, uint256)
    {
        uint256 length = size;

        if (length > userMatches[user].length - cursor) {
            length = userMatches[user].length - cursor;
        }

        uint256[] memory values = new uint256[](length);
        bool[] memory claimables = new bool[](length);
        BetInfo[] memory betInfo = new BetInfo[](length);

        for (uint256 i = 0; i < length; i++) {
            values[i] = userMatches[user][cursor + i];
            claimables[i] = claimable(values[i], user);
            betInfo[i] = ledger[values[i]][user];
        }

        return (values, betInfo, claimables, cursor + length);
    }

    /**
     * @notice Returns match fixtures length
     * @param user: user address
     */
    function getUserMatchesLength(address user) external view returns (uint256) {
        return userMatches[user].length;
    }

    /**
     * @notice Get the claimable stats of specific fixture and user account
     * @param fixture: fixture
     * @param user: user address
     */
    function claimable(uint256 fixture, address user) public view returns (bool) {
        BetInfo memory betInfo = ledger[fixture][user];
        Match memory mm = matches[fixture];
        if (mm.matchResult == 0) {
            return false;
        }
        return
        betInfo.amount != 0 &&
        !betInfo.claimed &&
        ((mm.matchResult == 1 && betInfo.position == Position.Home) ||
        (mm.matchResult == 3 && betInfo.position == Position.Draw) ||
        (mm.matchResult == 2 && betInfo.position == Position.Away));
    }

    /**
     * @notice Get the refundable stats of specific fixture and user account
     * @param fixture: fixture
     * @param user: user address
     */
    function refundable(uint256 fixture, address user) public view returns (bool) {
        BetInfo memory betInfo = ledger[fixture][user];
        Match memory mm = matches[fixture];
        return
        !betInfo.claimed &&
        block.timestamp > mm.closeTimestamp - bufferSeconds &&
        betInfo.amount != 0;
    }

    /**
     * @notice Calculate rewards for match
     * @param fixture: fixture
     */
    function _calculateRewards(uint256 fixture) internal {
        require(matches[fixture].rewardBaseCalAmount == 0 && matches[fixture].rewardAmount == 0, "Rewards calculated");
        Match storage mm = matches[fixture];
        uint256 rewardBaseCalAmount;
        uint256 treasuryAmt;
        uint256 rewardAmount;

        // Home wins
        if (matches[fixture].matchResult == 1) {
            rewardBaseCalAmount = mm.homeAmount;
            treasuryAmt = (mm.totalAmount * treasuryFee) / 10000;
            rewardAmount = mm.totalAmount - treasuryAmt;
        }
        // Away wins
        else if (matches[fixture].matchResult == 2) {
            rewardBaseCalAmount = mm.awayAmount;
            treasuryAmt = (mm.totalAmount * treasuryFee) / 10000;
            rewardAmount = mm.totalAmount - treasuryAmt;
        }
        //Draw
        else if (matches[fixture].matchResult == 3) {
            rewardBaseCalAmount = mm.drawAmount;
            treasuryAmt = (mm.totalAmount * treasuryFee) / 10000;
            rewardAmount = mm.totalAmount - treasuryAmt;
        }

        mm.rewardBaseCalAmount = rewardBaseCalAmount;
        mm.rewardAmount = rewardAmount;

        // Add to treasury
        treasuryAmount += treasuryAmt;

        emit RewardsCalculated(fixture, rewardBaseCalAmount, rewardAmount, treasuryAmt);
    }

    function fetchWeeklyMatches(uint256[] memory fixtures) external view returns (Match[] memory) {
        Match[] memory weeklyMatches = new Match[](fixtures.length);
        for (uint256 i = 0; i < fixtures.length; i++) {
            weeklyMatches[i] = matches[fixtures[i]];
        }
        return weeklyMatches;
    }

    /**
     * @notice End match
     */
    function _safeEndMatch(
        uint256 fixture,
        uint256 matchResult
    ) internal {
        require(matches[fixture].lockTimestamp != 0, "Can only end match after match has locked");
        require(block.timestamp >= matches[fixture].closeTimestamp, "Can only end match after closeTimestamp");

        Match storage mm = matches[fixture];
        mm.matchResult = matchResult;
        mm.finished = true;
        mm.closeTimestamp = block.timestamp;
        _calculateRewards(fixture);

        emit EndMatch(fixture, matchResult, true);
    }

    /**
     * @notice Start match
     */
    function _safeStartMatch(uint256 fixture, uint256 startTimestamp) internal {
        _startMatch(fixture, startTimestamp);
    }

    /**
     * @notice Transfer MATIC in a safe way
     * @param to: address to transfer MATIC to
     * @param value: MATIC amount to transfer (in wei)
     */
    function _safeTransferMATIC(address to, uint256 value) internal {
        (bool success,) = to.call{value : value}("");
        require(success, "TransferHelper: MATIC_TRANSFER_FAILED");
    }

    function _safeTransferToken(address to, uint256 value) internal {
        IERC20(tokenAddress).safeTransfer(to, value);
    }

    /**
     * @notice Start match
     * @param fixture: fixture
     */
    function _startMatch(uint256 fixture, uint256 startTimestamp) internal {
        require(startTimestamp > block.timestamp, "Start timestamp must be in the future");
        Match storage mm = matches[fixture];
        mm.startTimestamp = startTimestamp;
        mm.lockTimestamp = startTimestamp - bufferSeconds;
        mm.fixture = fixture;
        mm.totalAmount = 0;

        emit StartMatch(fixture);
    }

    /**
     * @notice Determine if a match is valid for receiving bets
     * Match must have started and locked
     * Current timestamp must be within startTimestamp and closeTimestamp
     */
    function _betTable(uint256 fixture) internal view returns (bool) {
        return
        matches[fixture].startTimestamp != 0 &&
        matches[fixture].lockTimestamp != 0 &&
        block.timestamp < matches[fixture].startTimestamp &&
        block.timestamp < matches[fixture].lockTimestamp;
    }

    function setFixtureResult(uint256 fixture, uint8 result) public onlyOperator {
        _safeEndMatch(fixture, result);
    }

    function setFixtureStart(uint256 fixture, uint256 startTimestamp) public onlyOperator {
        _safeStartMatch(fixture, startTimestamp);
    }

    function setFixtureStartBunch(uint256[] memory fixtures, uint256[] memory startTimestamps) public onlyOperator {
        for (uint256 i = 0; i < fixtures.length; i++) {
            _safeStartMatch(fixtures[i], startTimestamps[i]);
        }
    }

    function setFixtureResultBunch(uint256[] memory fixtures, uint8[] memory results) public onlyOperator {
        for (uint256 i = 0; i < fixtures.length; i++) {
            _safeEndMatch(fixtures[i], results[i]);
        }
    }

    function withdraw() public onlyOwner {
        uint256 balance = address(this).balance;
        uint256 tokenBalance = IERC20(tokenAddress).balanceOf(address(this));

        _safeTransferMATIC(msg.sender, balance);
        _safeTransferToken(msg.sender, tokenBalance);
    }
    /**
     * @notice Returns true if `account` is a contract.
     * @param account: account address
     */
    function _isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }
}