// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

interface IERC20 {
    function totalSupply() external pure returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner_, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

contract GambleX is IERC20 {
    string private constant _name = "GambleX";
    string private constant _symbol = "GMBLX";
    uint8 private constant _decimals = 18;

    uint256 private constant _totalSupply = 100_000_000 * 1e18;

    address public immutable feeWallet;
    address public immutable mainWallet;

    uint256 private constant _FEE_PERCENT = 5; // Represents 0.5%
    uint256 private constant _FEE_DIVISOR = 1000;

    struct Account {
        uint256 balance;
        bool isBlacklisted;
    }

    mapping(address => Account) private _accounts;
    mapping(address => mapping(address => uint256)) private _allowances;

    address private _owner;
    address private _pendingOwner;

    error NotOwner();
    error Blacklisted(address account);
    error InvalidRecipient();
    error InsufficientBalance();
    error TransferFailed();
    error ZeroAddress();
    error NoETHToWithdraw();
    error TokenAddressNotContract();
    error AllowanceExceeded();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event AddedToBlacklist(address indexed account);
    event RemovedFromBlacklist(address indexed account);
    event EmergencyWithdrawal(address indexed token, uint256 amount);
    event OwnershipTransferInitiated(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ETHWithdrawn(address indexed owner, uint256 amount);

    modifier onlyOwner() {
        if (msg.sender != _owner) revert NotOwner();
        _;
    }

    modifier notBlacklisted(address account) {
        if (_accounts[account].isBlacklisted) revert Blacklisted(account);
        _;
    }

    modifier validRecipient(address recipient) {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        _;
    }

    constructor(address _feeWalletAddress, address _mainWalletAddress) payable {
        if (_feeWalletAddress == address(0)) revert ZeroAddress();
        if (_mainWalletAddress == address(0)) revert ZeroAddress();

        feeWallet = _feeWalletAddress;
        mainWallet = _mainWalletAddress;
        _owner = _mainWalletAddress;
        _accounts[_mainWalletAddress].balance = _totalSupply;
        emit Transfer(address(0), _mainWalletAddress, _totalSupply);
    }

    receive() external payable {
        revert("Cannot send ETH to this contract");
    }

    fallback() external payable {
        revert("Cannot send ETH to this contract");
    }

    function name() external pure returns (string memory) {
        return _name;
    }

    function symbol() external pure returns (string memory) {
        return _symbol;
    }

    function decimals() external pure returns (uint8) {
        return _decimals;
    }

    function totalSupply() external pure override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _accounts[account].balance;
    }

    function transfer(address recipient, uint256 amount)
        external
        override
        notBlacklisted(msg.sender)
        notBlacklisted(recipient)
        validRecipient(recipient)
        returns (bool)
    {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner_, address spender) external view override returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        if (spender == address(0)) revert ZeroAddress();

        if (_allowances[msg.sender][spender] != amount) {
            _allowances[msg.sender][spender] = amount;
            emit Approval(msg.sender, spender, amount);
        }
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    )
        external
        override
        notBlacklisted(sender)
        notBlacklisted(recipient)
        validRecipient(recipient)
        returns (bool)
    {
        uint256 currentAllowance = _allowances[sender][msg.sender];
        if (currentAllowance < amount) revert AllowanceExceeded();

        unchecked {
            _allowances[sender][msg.sender] = currentAllowance - amount;
        }
        emit Approval(sender, msg.sender, _allowances[sender][msg.sender]);

        _transfer(sender, recipient, amount);
        return true;
    }

    function addToBlacklist(address account) external payable onlyOwner {
        if (_accounts[account].isBlacklisted) revert Blacklisted(account);
        _accounts[account].isBlacklisted = true;
        emit AddedToBlacklist(account);
    }

    function removeFromBlacklist(address account) external payable onlyOwner {
        if (!_accounts[account].isBlacklisted) revert Blacklisted(account);
        _accounts[account].isBlacklisted = false;
        emit RemovedFromBlacklist(account);
    }

    function emergencyWithdraw(address tokenAddress, uint256 amount) external payable onlyOwner {
        if (tokenAddress.code.length == 0) revert TokenAddressNotContract();
        bool success = IERC20(tokenAddress).transfer(_owner, amount);
        if (!success) revert TransferFailed();
        emit EmergencyWithdrawal(tokenAddress, amount);
    }

    function withdrawETH() external payable onlyOwner {
        uint256 ethBalance;
        assembly {
            ethBalance := selfbalance()
        }
        if (ethBalance == 0) revert NoETHToWithdraw();
        (bool success, ) = _owner.call{value: ethBalance}("");
        if (!success) revert TransferFailed();
        emit ETHWithdrawn(_owner, ethBalance);
    }

    function initiateOwnershipTransfer(address newOwner) external payable onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        _pendingOwner = newOwner;
        emit OwnershipTransferInitiated(_owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != _pendingOwner) revert NotOwner();
        if (_owner != _pendingOwner) {
            address previousOwner = _owner;
            _owner = _pendingOwner;
            _pendingOwner = address(0);
            emit OwnershipTransferred(previousOwner, _owner);
        } else {
            _pendingOwner = address(0);
        }
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    )
        internal
    {
        Account storage senderAccount = _accounts[sender];
        Account storage recipientAccount = _accounts[recipient];
        uint256 senderBalance = senderAccount.balance;
        if (senderBalance < amount) revert InsufficientBalance();

        uint256 feeAmount = (amount * _FEE_PERCENT + (_FEE_DIVISOR >> 1)) / _FEE_DIVISOR;
        uint256 transferAmount = amount - feeAmount;

        // Check for rounding errors
        require(feeAmount + transferAmount == amount, "Invalid transfer amount");

        unchecked {
            senderAccount.balance = senderBalance - amount;
            _accounts[feeWallet].balance += feeAmount;
            recipientAccount.balance += transferAmount;
        }

        emit Transfer(sender, feeWallet, feeAmount);
        emit Transfer(sender, recipient, transferAmount);
    }
}