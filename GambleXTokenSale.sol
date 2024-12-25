// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title GambleXTokenSale
 * @notice A token sale contract with optional Chainlink price feed integration,
 *         global vesting start time, and configurable fee/duration parameters.
 */
contract GambleXTokenSale is Ownable, Pausable, ReentrancyGuard {
    // ============ Errors ============
    error SalePaused();
    error SaleInactive();
    error InvalidAddress();
    error InvalidETHPrice();
    error NoETHSent();
    error TransferFailed();
    error TransferFromFailed();
    error NotEnoughTokensAvailable();
    error VestingNotLaunched();
    error AlreadyLaunched();
    error NoVestingSchedule();
    error NoTokensToClaim();
    error ZeroAmount();
    error VestingAlreadyStarted();
    error VestingParametersLocked();

    // ============ State Variables ============

    IERC20 public token;
    AggregatorV3Interface public ethUsdPriceFeed;
    address public treasuryWallet;

    uint256 public tokensAvailable;
    uint256 public constant TOTAL_TOKENS_FOR_SALE = 5_000_000 * 10**18;

    // Token price: 0.08 USD (scaled by 1e18 for precision).
    uint256 public constant TOKEN_PRICE_IN_USD = 8e16;

    // The vesting schedule splits the locked portion into 6 intervals.
    uint256 public constant TOTAL_PORTIONS = 6;

    // portionDuration replaces the "30 days" reliance.
    // By default, it's 30 days. The owner can modify it, but ONLY before vesting starts.
    uint256 public portionDuration = 30 days; 

    // Configurable fee (default ~0.5%).
    // For instance, 1000 / 995 = ~1.005, i.e., ~0.5% difference.
    uint256 public feeNumerator = 1000;
    uint256 public feeDenominator = 995;

    // If set to true, the contract will use the fallback ETH price (ethPriceInUSD).
    bool public useFallbackPrice = false;

    // The fallback ETH price in USD (scaled by 1e18 for precision).
    uint256 public ethPriceInUSD;

    // Whether the owner has started the vesting period globally.
    bool public vestingLaunched;
    uint256 public vestingLaunchTime;

    struct VestingSchedule {
        uint256 totalAllocated; // total locked (after the immediate release)
        uint256 claimed;        // total claimed from the vesting portion
    }

    mapping(address => VestingSchedule) public vestingSchedules;

    // ============ Events ============

    event TokensPurchased(address indexed buyer, uint256 ethSpent, uint256 tokensAllocated);
    event TokensClaimed(address indexed claimer, uint256 tokensClaimed);
    event SaleStarted();
    event SaleStopped();
    event ETHPriceUpdated(uint256 newPrice);
    event UseFallbackPriceUpdated(bool useFallback);
    event PriceFeedUpdated(address newPriceFeed);
    event VestingStarted(uint256 startTime);
    event PortionDurationUpdated(uint256 newDuration);
    event FeeUpdated(uint256 newNumerator, uint256 newDenominator);

    // ============ Constructor ============

    constructor(
        address _token,
        address _ethUsdPriceFeed,
        address _treasuryWallet,
        uint256 _ethPriceInUSD
    ) Ownable(msg.sender) {
        if (_token == address(0)) revert InvalidAddress();
        if (_ethUsdPriceFeed == address(0)) revert InvalidAddress();
        if (_treasuryWallet == address(0)) revert InvalidAddress();
        if (_ethPriceInUSD == 0) revert InvalidETHPrice();

        token = IERC20(_token);
        ethUsdPriceFeed = AggregatorV3Interface(_ethUsdPriceFeed);
        treasuryWallet = _treasuryWallet;
        tokensAvailable = TOTAL_TOKENS_FOR_SALE;
        ethPriceInUSD = _ethPriceInUSD;
    }

    // ============ Modifiers ============

    modifier saleActive() {
        if (paused()) revert SalePaused();
        if (tokensAvailable == 0) revert SaleInactive();
        _;
    }

    // ============ Owner Functions ============

    /**
     * @notice Unpause the sale, allowing token purchases.
     */
    function startSale() external onlyOwner whenPaused {
        _unpause();
        emit SaleStarted();
    }

    /**
     * @notice Pause the sale, disallowing token purchases.
     */
    function stopSale() external onlyOwner whenNotPaused {
        _pause();
        emit SaleStopped();
    }

    /**
     * @notice Disables the buy function once vesting is launched.
     *         This is to ensure no one can buy after vesting period begins.
     */
    function startVestingPeriod() external onlyOwner {
        if (vestingLaunched) revert AlreadyLaunched();
        vestingLaunched = true;
        vestingLaunchTime = block.timestamp;
        emit VestingStarted(vestingLaunchTime);
    }

    /**
     * @notice Updates the fallback ETH price in USD (1e18 scaled).
     */
    function updateETHPrice(uint256 newEthPriceInUSD) external onlyOwner {
        if (newEthPriceInUSD == 0) revert InvalidETHPrice();
        ethPriceInUSD = newEthPriceInUSD;
        emit ETHPriceUpdated(newEthPriceInUSD);
    }

    /**
     * @notice Toggles whether the contract uses the fallback price or the Chainlink oracle.
     */
    function updateUseFallbackPrice(bool _useFallback) external onlyOwner {
        useFallbackPrice = _useFallback;
        emit UseFallbackPriceUpdated(_useFallback);
    }

    /**
     * @notice Updates the Chainlink price feed contract address.
     */
    function setPriceFeed(address newPriceFeed) external onlyOwner {
        if (newPriceFeed == address(0)) revert InvalidAddress();
        ethUsdPriceFeed = AggregatorV3Interface(newPriceFeed);
        emit PriceFeedUpdated(newPriceFeed);
    }

    /**
     * @notice Allows the owner to update the single-interval duration.
     *         By default it's 30 days, but you can set a different value to reduce reliance on "30 days".
     *         This cannot be updated once vesting has started.
     */
    function setPortionDuration(uint256 newDuration) external onlyOwner {
        if (newDuration == 0) revert ZeroAmount();
        if (vestingLaunched) revert VestingParametersLocked();
        portionDuration = newDuration;
        emit PortionDurationUpdated(newDuration);
    }

    /**
     * @notice Allows the owner to update the fee parameters.
     *         For example, to set a 1% fee, you might do (1010, 1000).
     */
    function setFee(uint256 newNumerator, uint256 newDenominator) external onlyOwner {
        if (newDenominator == 0) revert ZeroAmount();
        feeNumerator = newNumerator;
        feeDenominator = newDenominator;
        emit FeeUpdated(newNumerator, newDenominator);
    }

    // ============ View Functions ============

    function isPaused() external view returns (bool) {
        return paused();
    }

    function isSaleActive() external view returns (bool) {
        return !paused() && tokensAvailable > 0 && !vestingLaunched;
    }

    /**
     * @notice Total vesting duration in seconds = portionDuration * 6.
     */
    function getTotalVestingDuration() public view returns (uint256) {
        return portionDuration * TOTAL_PORTIONS;
    }

    /**
     * @notice Get the current ETH price (1e18 scaled).
     *         Either from Chainlink or fallback, depending on useFallbackPrice.
     */
    function getCurrentETHPrice() external view returns (uint256) {
        return _getCurrentETHPriceInternal();
    }

    /**
     * @notice Returns how many seconds remain until the next vesting portion for user.
     */
    function getTimeUntilNextVesting(address user) external view returns (uint256) {
        VestingSchedule storage schedule = vestingSchedules[user];
        if (schedule.totalAllocated == 0) revert NoVestingSchedule();
        if (!vestingLaunched) {
            // If vesting hasn't started, treat as infinitely far away.
            // The user can't claim until vestingLaunched is true.
            return type(uint256).max;
        }

        uint256 portionClaimed = (schedule.claimed * TOTAL_PORTIONS) / schedule.totalAllocated;
        if (portionClaimed >= TOTAL_PORTIONS) {
            return 0; // Fully vested
        }

        uint256 nextVestingTime = vestingLaunchTime + (portionClaimed + 1) * portionDuration;
        if (block.timestamp >= nextVestingTime) {
            return 0;
        } else {
            return nextVestingTime - block.timestamp;
        }
    }

    /**
     * @notice Returns the total time left (in seconds) until all tokens are fully vested for user.
     */
    function getTotalTimeUntilVestingComplete(address user) external view returns (uint256) {
        VestingSchedule storage schedule = vestingSchedules[user];
        if (schedule.totalAllocated == 0) revert NoVestingSchedule();
        if (!vestingLaunched) {
            // If vesting not launched, they still have the full interval ahead (6 portions).
            return getTotalVestingDuration();
        }

        uint256 vestingEndTime = vestingLaunchTime + getTotalVestingDuration();
        if (block.timestamp >= vestingEndTime) {
            return 0;
        } else {
            return vestingEndTime - block.timestamp;
        }
    }

    /**
     * @notice Returns how many seconds until the next vesting portion after the user claims.
     */
    function getNextVestingTime(address user) external view returns (uint256) {
        VestingSchedule storage schedule = vestingSchedules[user];
        if (schedule.totalAllocated == 0) revert NoVestingSchedule();
        if (!vestingLaunched) return type(uint256).max;

        uint256 portionClaimed = (schedule.claimed * TOTAL_PORTIONS) / schedule.totalAllocated;
        if (portionClaimed >= TOTAL_PORTIONS) {
            return 0; // No more vesting remains
        }

        uint256 nextVestingTime = vestingLaunchTime + (portionClaimed + 1) * portionDuration;
        if (block.timestamp >= nextVestingTime) {
            return 0;
        } else {
            return nextVestingTime - block.timestamp;
        }
    }

    /**
     * @notice Returns how many tokens the user still has in vesting (i.e., not yet claimed).
     */
    function getRemainingTokensInVesting(address user) external view returns (uint256) {
        VestingSchedule storage schedule = vestingSchedules[user];
        if (schedule.totalAllocated == 0) revert NoVestingSchedule();
        return schedule.totalAllocated - schedule.claimed;
    }

    /**
     * @notice Returns how many tokens the user has claimed so far.
     */
    function getClaimedTokens(address user) external view returns (uint256) {
        VestingSchedule storage schedule = vestingSchedules[user];
        if (schedule.totalAllocated == 0) revert NoVestingSchedule();
        return schedule.claimed;
    }

    // ============ Emergency Functions ============

    /**
     * @notice Withdraw all ETH held in the contract to the owner.
     *         Used only in emergencies.
     */
    function emergencyWithdrawETH() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        if (balance == 0) revert ZeroAmount();
        (bool success, ) = payable(owner()).call{value: balance}("");
        if (!success) revert TransferFailed();
    }

    /**
     * @notice Withdraw tokens (held by the contract) to the owner.
     *         Used only in emergencies.
     */
    function emergencyWithdrawTokens(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _safeTransfer(token, owner(), amount);
    }

    // ============ Purchase & Vesting Logic ============

    /**
     * @notice Buy tokens with ETH. Includes an immediate release and
     *         sets up the user's vesting schedule for the remainder.
     *         Disabled once vesting has started.
     */
    function buyTokens() external payable whenNotPaused saleActive nonReentrant {
        // New requirement: can't buy if vesting already launched.
        if (vestingLaunched) revert VestingAlreadyStarted();

        if (msg.value == 0) revert NoETHSent();

        uint256 tokenPriceInETH = _getTokenPriceInETH();
        if (tokenPriceInETH == 0) revert InvalidETHPrice();

        // Calculate the number of tokens to allocate (before adjusting for fee).
        uint256 tokensToAllocate = (msg.value * 1e18) / tokenPriceInETH;

        // Adjust for the fee.
        // Example: (tokens * 1000) / 995 => ~0.5% difference
        uint256 adjustedTokensToAllocate = (tokensToAllocate * feeNumerator) / feeDenominator;
        if (adjustedTokensToAllocate == 0) revert ZeroAmount();
        if (adjustedTokensToAllocate > tokensAvailable) revert NotEnoughTokensAvailable();

        // Immediate release: 1/6
        uint256 initialRelease = (adjustedTokensToAllocate * 1) / 6;
        // Remaining to be vested
        uint256 vestingAmount = adjustedTokensToAllocate - initialRelease;

        // If user already has a vesting schedule, add to it instead of overwriting
        VestingSchedule storage schedule = vestingSchedules[msg.sender];
        schedule.totalAllocated += vestingAmount;

        // Deduct tokens from sale availability
        tokensAvailable -= adjustedTokensToAllocate;

        // Transfer ETH to treasury
        (bool success, ) = payable(treasuryWallet).call{value: msg.value}("");
        if (!success) revert TransferFailed();

        // Transfer the immediate-release portion to the buyer (with fee offset again)
        uint256 effectiveInitialRelease = (initialRelease * feeNumerator) / feeDenominator;
        _safeTransferFrom(token, treasuryWallet, msg.sender, effectiveInitialRelease);

        emit TokensPurchased(msg.sender, msg.value, adjustedTokensToAllocate);
    }

    /**
     * @notice Claim the vested tokens that the sender is entitled to.
     */
    function claimTokens() external nonReentrant {
        VestingSchedule storage schedule = vestingSchedules[msg.sender];
        if (schedule.totalAllocated == 0) revert NoVestingSchedule();
        if (!vestingLaunched) revert VestingNotLaunched();

        // How many intervals have elapsed?
        uint256 intervalsElapsed = (block.timestamp - vestingLaunchTime) / portionDuration;
        if (intervalsElapsed == 0) revert NoTokensToClaim();
        if (intervalsElapsed > TOTAL_PORTIONS) {
            intervalsElapsed = TOTAL_PORTIONS;
        }

        // Max claimable is intervalsElapsed/6 of total allocated
        uint256 maxClaimable = (schedule.totalAllocated * intervalsElapsed) / TOTAL_PORTIONS;

        // The user can only claim what they haven't claimed before.
        uint256 claimable = maxClaimable - schedule.claimed;
        if (claimable == 0) revert NoTokensToClaim();

        // Adjust claimable for the fee
        uint256 effectiveClaimable = (claimable * feeNumerator) / feeDenominator;

        // Update user's claimed amount
        schedule.claimed += claimable;

        // Transfer tokens to user
        _safeTransferFrom(token, treasuryWallet, msg.sender, effectiveClaimable);

        emit TokensClaimed(msg.sender, claimable);
    }

    /**
     * @notice Helper function to see how many tokens one would receive for a given ETH amount (pre-fee).
     */
    function calculateTokensForETH(uint256 ethAmount) external view returns (uint256) {
        uint256 tokenPriceInETH = _getTokenPriceInETH();
        if (tokenPriceInETH == 0) return 0;
        return (ethAmount * 1e18) / tokenPriceInETH;
    }

    // ============ Internal Functions ============

    /**
     * @notice Return the token price in ETH scaled to 1e18.
     */
    function _getTokenPriceInETH() internal view returns (uint256) {
        uint256 ethUsd = _getCurrentETHPriceInternal();
        // Token price in ETH = (TOKEN_PRICE_IN_USD * 1e18) / ethUsd
        // Both TOKEN_PRICE_IN_USD and ethUsd are scaled by 1e18
        if (ethUsd == 0) return 0;
        return (TOKEN_PRICE_IN_USD * 1e18) / ethUsd;
    }

    /**
     * @notice Attempt to fetch the ETH/USD price from Chainlink. 
     *         Falls back to manual price if oracle fails or if useFallbackPrice is true.
     */
    function _getCurrentETHPriceInternal() internal view returns (uint256) {
        if (!useFallbackPrice) {
            // Attempt to fetch from Chainlink
            try ethUsdPriceFeed.latestRoundData() returns (
                uint80 /*roundID*/,
                int256 price,
                uint256 /*startedAt*/,
                uint256 /*timeStamp*/,
                uint80 /*answeredInRound*/
            ) {
                if (price <= 0) {
                    // If invalid, fallback
                    return ethPriceInUSD;
                }
                // Chainlink price typically is 1e8; multiply by 1e10 to scale to 1e18.
                return uint256(price) * 1e10;
            } catch {
                // On failure, fallback
                return ethPriceInUSD;
            }
        } else {
            // Manual price only
            return ethPriceInUSD;
        }
    }

    /**
     * @notice Wrapper that ensures an ERC20 transfer reverts on failure.
     */
    function _safeTransfer(IERC20 _token, address _to, uint256 _amount) internal {
        (bool success, bytes memory data) =
            address(_token).call(abi.encodeWithSelector(_token.transfer.selector, _to, _amount));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    /**
     * @notice Wrapper that ensures an ERC20 transferFrom reverts on failure.
     */
    function _safeTransferFrom(IERC20 _token, address _from, address _to, uint256 _amount) internal {
        (bool success, bytes memory data) =
            address(_token).call(abi.encodeWithSelector(_token.transferFrom.selector, _from, _to, _amount));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFromFailed();
    }
}
