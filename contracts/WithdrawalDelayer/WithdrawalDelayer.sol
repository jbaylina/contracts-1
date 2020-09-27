// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/Initializable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC777/IERC777Recipient.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/introspection/IERC1820Registry.sol";

contract WithdrawalDelayer is
    Initializable,
    ReentrancyGuardUpgradeSafe,
    IERC777Recipient
{
    struct DepositState {
        uint192 amount;
        uint64 depositTimestamp;
    }
    bytes4 private constant _TRANSFER_SIGNATURE = bytes4(
        keccak256(bytes("transfer(address,uint256)"))
    );
    bytes4 private constant _TRANSFERFROM_SIGNATURE = bytes4(
        keccak256(bytes("transferFrom(address,address,uint256)"))
    );
    bytes4 private constant _SEND_SIGNATURE = bytes4(
        keccak256(bytes("send(address,uint256,bytes)"))
    );
    bytes4 private constant _DEPOSIT_SIGNATURE = bytes4(
        keccak256(bytes("deposit(address,address,uint192)"))
    );

    IERC1820Registry private constant _ERC1820_REGISTRY = IERC1820Registry(
        0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24
    );
    bytes32 private constant _ERC777_RECIPIENT_INTERFACE_HASH = keccak256(
        "ERC777TokensRecipient"
    );
    uint64 public constant MAX_WITHDRAWAL_DELAY = 2 weeks;
    uint64 public constant MAX_EMERGENCY_MODE_TIME = 26 weeks;
    uint64 private _withdrawalDelay;
    uint64 private _emergencyModeStartingTime;
    address private _hermezGovernanceDAOAddress;
    address payable private _whiteHackGroupAddress;
    address private _hermezKeeperAddress;
    bool private _emergencyMode;
    address public hermezRollupAddress;
    mapping(bytes32 => DepositState) public deposits;

    event Deposit(
        address indexed owner,
        address indexed token,
        uint192 amount,
        uint64 depositTimestamp
    );
    event Withdraw(
        address indexed token,
        address indexed owner,
        uint192 amount
    );
    event EmergencyModeEnabled();
    event NewWithdrawalDelay(uint64 withdrawalDelay);
    event EscapeHatchWithdrawal(
        address indexed who,
        address indexed to,
        address indexed token
    );
    event NewHermezKeeperAddress(address newHermezKeeperAddress);
    event NewWhiteHackGroupAddress(address newWhiteHackGroupAddress);
    event NewHermezGovernanceDAOAddress(address newHermezGovernanceDAOAddress);

    /**
     * @notice withdrawalDelayerInitializer (Constructor)
     * @param _initialWithdrawalDelay Initial withdrawal delay time in seconds to be able to withdraw the funds
     * @param _initialHermezRollup Smart contract responsible of making deposits and it's able to change the delay
     * @param _initialHermezKeeperAddress can enable emergency mode and modify the delay to make a withdrawal
     * @param _initialHermezGovernanceDAOAddress can claim the funds in an emergency mode
     * @param _initialWhiteHackGroupAddress can claim the funds in an emergency and MAX_EMERGENCY_MODE_TIME exceeded
     */

    function withdrawalDelayerInitializer(
        uint64 _initialWithdrawalDelay,
        address _initialHermezRollup,
        address _initialHermezKeeperAddress,
        address _initialHermezGovernanceDAOAddress,
        address payable _initialWhiteHackGroupAddress
    ) public initializer {
        __ReentrancyGuard_init_unchained();
        _withdrawalDelay = _initialWithdrawalDelay;
        hermezRollupAddress = _initialHermezRollup;
        _hermezKeeperAddress = _initialHermezKeeperAddress;
        _hermezGovernanceDAOAddress = _initialHermezGovernanceDAOAddress;
        _whiteHackGroupAddress = _initialWhiteHackGroupAddress;
        _emergencyMode = false;
        _ERC1820_REGISTRY.setInterfaceImplementer(
            address(this),
            _ERC777_RECIPIENT_INTERFACE_HASH,
            address(this)
        );
    }

    /**
     * @notice Getter of the current `_hermezGovernanceDAOAddress`
     * @return The `_hermezGovernanceDAOAddress` value
     */
    function getHermezGovernanceDAOAddress() external view returns (address) {
        return _hermezGovernanceDAOAddress;
    }

    /**
     * @notice Allows to change the `_hermezGovernanceDAOAddress` if it's called by `_hermezGovernanceDAOAddress`
     * @param newAddress new `_hermezGovernanceDAOAddress`
     */
    function setHermezGovernanceDAOAddress(address newAddress) external {
        require(
            msg.sender == _hermezGovernanceDAOAddress,
            "Only Hermez Governance DAO"
        );
        _hermezGovernanceDAOAddress = newAddress;
        emit NewHermezGovernanceDAOAddress(_hermezGovernanceDAOAddress);
    }

    /**
     * @notice Getter of the current `_hermezKeeperAddress`
     * @return The `_hermezKeeperAddress` value
     */
    function getHermezKeeperAddress() external view returns (address) {
        return _hermezKeeperAddress;
    }

    /**
     * @notice Allows to change the `_hermezKeeperAddress` if it's called by `_hermezKeeperAddress`
     * @param newAddress `_hermezKeeperAddress`
     */
    function setHermezKeeperAddress(address newAddress) external {
        require(
            msg.sender == _hermezKeeperAddress,
            "Only Hermez Keeper Address"
        );
        _hermezKeeperAddress = newAddress;
        emit NewHermezKeeperAddress(_hermezKeeperAddress);
    }

    /**
     * @notice Getter of the current `_whiteHackGroupAddress`
     * @return The `_whiteHackGroupAddress` value
     */
    function getWhiteHackGroupAddress() external view returns (address) {
        return _whiteHackGroupAddress;
    }

    /**
     * @notice Allows to change the `_whiteHackGroupAddress` if it's called by `_whiteHackGroupAddress`
     * @param newAddress new `_whiteHackGroupAddress`
     */
    function setWhiteHackGroupAddress(address payable newAddress) external {
        require(msg.sender == _whiteHackGroupAddress, "Only WHG address");
        _whiteHackGroupAddress = newAddress;
        emit NewWhiteHackGroupAddress(_whiteHackGroupAddress);
    }

    /**
     * @notice Getter of the current `_emergencyMode` status to know if the emergency mode is enable or disable
     * @return The `_emergencyMode` value
     */
    function isEmergencyMode() external view returns (bool) {
        return _emergencyMode;
    }

    /**
     * @notice Getter to obtain the current withdrawal delay
     * @return the current withdrawal delay time in seconds: `_withdrawalDelay`
     */
    function getWithdrawalDelay() external view returns (uint128) {
        return _withdrawalDelay;
    }

    /**
     * @notice Getter to obtain when emergency mode started
     * @return the emergency mode starting time in seconds: `_emergencyModeStartingTime`
     */
    function getEmergencyModeStartingTime() external view returns (uint128) {
        return _emergencyModeStartingTime;
    }

    /**
     * @notice This function enables the emergency mode. Only the keeper of the system can enable this mode. This cannot
     * be deactivated in any case so it will be irreversible.
     * @dev The activation time is saved in `_emergencyModeStartingTime` and this function can only be called
     * once if it has not been previously activated.
     * Events: `EmergencyModeEnabled` event.
     */
    function enableEmergencyMode() external {
        require(msg.sender == _hermezKeeperAddress, "Only hermezKeeperAddress");
        require(!_emergencyMode, "Emergency mode already enabled");
        _emergencyMode = true;
        /* solhint-disable not-rely-on-time */
        _emergencyModeStartingTime = uint64(now);
        emit EmergencyModeEnabled();
    }

    /**
     * @notice This function allows the HermezKeeperAddress to change the withdrawal delay time, this is the time that
     * anyone needs to wait until a withdrawal of the funds is allowed. Since this time is calculated at the time of
     * withdrawal, this change affects existing deposits. Can never exceed `MAX_WITHDRAWAL_DELAY`
     * @dev It changes `_withdrawalDelay` if `_newWithdrawalDelay` it is less than or equal to MAX_WITHDRAWAL_DELAY
     * @param _newWithdrawalDelay new delay time in seconds
     * Events: `NewWithdrawalDelay` event.
     */
    function changeWithdrawalDelay(uint64 _newWithdrawalDelay) external {
        require(
            (msg.sender == _hermezKeeperAddress) ||
                (msg.sender == hermezRollupAddress),
            "Only hermez keeper or rollup"
        );
        require(
            _newWithdrawalDelay <= MAX_WITHDRAWAL_DELAY,
            "Exceeds MAX_WITHDRAWAL_DELAY"
        );
        _withdrawalDelay = _newWithdrawalDelay;
        emit NewWithdrawalDelay(_withdrawalDelay);
    }

    /**
     * Returns the balance and the timestamp for a specific owner and token
     * @param _owner who can claim the deposit once the delay time has expired (if not in emergency mode)
     * @param _token address of the token to withdrawal (0x0 in case of Ether)
     * @return `amount` Total amount withdrawable (if not in emergency mode)
     * @return `depositTimestamp` Moment at which funds were deposited
     */
    function depositInfo(address payable _owner, address _token)
        external
        view
        returns (uint192, uint64)
    {
        DepositState memory ds = deposits[keccak256(
            abi.encodePacked(_owner, _token)
        )];
        return (ds.amount, ds.depositTimestamp);
    }

    /**
     * Function to make a deposit in the WithdrawalDelayer smartcontract, only the Hermez rollup smartcontract can do it
     * @dev In case of an Ether deposit, the address `0x0` will be used and the corresponding amount must be sent in the
     * `msg.value`. In case of an ERC20 this smartcontract must have the approval to expend the token to
     * deposit to be able to make a transferFrom to itself.
     * @param _owner is who can claim the deposit once the withdrawal delay time has been exceeded
     * @param _token address of the token deposited (`0x0` in case of Ether)
     * @param _amount deposit amount
     * Events: `Deposit`
     */
    function deposit(
        address _owner,
        address _token,
        uint192 _amount
    ) external payable nonReentrant {
        require(msg.sender == hermezRollupAddress, "Only hermezRollupAddress");
        if (msg.value != 0) {
            require(_token == address(0x0), "ETH should be the 0x0 address");
            require(_amount == msg.value, "Different amount and msg.value");
        } else {
            require(
                IERC20(_token).allowance(hermezRollupAddress, address(this)) >=
                    _amount,
                "Doesn't have enough allowance"
            );
            /* solhint-disable avoid-low-level-calls */
            (bool success, bytes memory data) = address(_token).call(
                abi.encodeWithSelector(
                    _TRANSFERFROM_SIGNATURE,
                    hermezRollupAddress,
                    address(this),
                    _amount
                )
            );
            // `transferFrom` method may return (bool) or nothing.
            require(
                success && (data.length == 0 || abi.decode(data, (bool))),
                "Token Transfer Failed"
            );
        }
        _processDeposit(_owner, _token, _amount);
    }

    /**
     * Function to make a deposit in the WithdrawalDelayer smartcontract, with an ERC777
     * @dev
     * @param operator - not used
     * @param from - not used
     * @param to - not used
     * @param amount the amount of tokens that have been sent
     * @param userData contains the raw call of the method to invoke (deposit)
     * @param operatorData - not used
     * Events: `Deposit`
     */
    function tokensReceived(
        // solhint-disable no-unused-vars
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes calldata userData,
        bytes calldata operatorData
    ) external override nonReentrant {
        require(from == hermezRollupAddress, "Only hermezRollupAddress");
        require(userData.length != 0, "UserData empty");

        // Decode the signature
        bytes4 sig = abi.decode(userData, (bytes4));
        // We only accept "deposit(address,address,uint192)"
        if (sig == _DEPOSIT_SIGNATURE) {
            (address _owner, address _token, uint192 _amount) = abi.decode(
                userData[4:],
                (address, address, uint192)
            );
            require(amount == _amount, "Amount sent different");
            _processDeposit(_owner, msg.sender, _amount);
        } else {
            revert("Not a valid calldata");
        }
    }

    /**
     * @notice Internal call to make a deposit
     * @param _owner is who can claim the deposit once the withdrawal delay time has been exceeded
     * @param _token address of the token deposited (`0x0` in case of Ether)
     * @param _amount deposit amount
     * Events: `Deposit`
     */
    function _processDeposit(
        address _owner,
        address _token,
        uint192 _amount
    ) internal {
        // We identify a deposit with the keccak of its owner and the token
        bytes32 depositId = keccak256(abi.encodePacked(_owner, _token));
        uint192 newAmount = deposits[depositId].amount + _amount;
        require(newAmount >= deposits[depositId].amount, "Deposit overflow");

        deposits[depositId].amount = newAmount;
        deposits[depositId].depositTimestamp = uint64(now);

        emit Deposit(
            _owner,
            _token,
            _amount,
            deposits[depositId].depositTimestamp
        );
    }

    /**
     * This function allows the owner to withdawal the funds. Emergency mode cannot be enabled and it must have exceeded
     * the withdrawal delay time
     * @dev `NonReentrant` modifier is used as a protection despite the state is being previously updated
     * @param _owner can claim the deposit once the delay time has expired
     * @param _token address of the token to withdrawal (0x0 in case of Ether)
     * Events: `Withdraw`
     */
    function withdrawal(address payable _owner, address _token)
        external
        nonReentrant
    {
        require(!_emergencyMode, "Emergency mode");
        // We identify a deposit with the keccak of its owner and the token
        bytes32 depositId = keccak256(abi.encodePacked(_owner, _token));
        uint192 amount = deposits[depositId].amount;
        require(amount > 0, "No funds to withdraw");
        require(
            deposits[depositId].depositTimestamp + _withdrawalDelay <=
                uint64(now),
            "Withdrawal not allowed yet"
        );

        // Update the state
        deposits[depositId].amount = 0;
        deposits[depositId].depositTimestamp = 0;

        // Make the transfer
        if (_token == address(0x0)) {
            _ethWithdrawal(_owner, uint256(amount));
        } else {
            _tokenWithdrawal(_token, _owner, uint256(amount));
        }

        emit Withdraw(_token, _owner, amount);
    }

    /**
     * Allows the Hermez Governance DAO to withdawal the funds in the event that emergency mode was enable.
     * Note: An Aragon Court will have the right to veto over the call to this method
     * @dev `NonReentrant` modifier is used as a protection despite the state is being previously updated and this is
     * a security mechanism
     * @param _to where the funds will be sent
     * @param _token address of the token withdraw (0x0 in case of Ether)
     * Events: `EscapeHatchWithdrawal`
     */
    function escapeHatchWithdrawal(address _to, address _token)
        external
        nonReentrant
    {
        require(_emergencyMode, "Only Emergency Mode");
        require(
            msg.sender == _whiteHackGroupAddress ||
                msg.sender == _hermezGovernanceDAOAddress,
            "Only GovernanceDAO or WHG"
        );
        if (msg.sender == _whiteHackGroupAddress) {
            require(
                _emergencyModeStartingTime + MAX_EMERGENCY_MODE_TIME <=
                    uint64(now),
                "NO MAX_EMERGENCY_MODE_TIME"
            );
        }
        uint256 amount;
        if (_token == address(0x0)) {
            amount = address(this).balance;
            _ethWithdrawal(_to, amount);
        } else {
            IERC20 token = IERC20(_token);
            amount = token.balanceOf(address(this));
            _tokenWithdrawal(_token, _to, amount);
        }
        emit EscapeHatchWithdrawal(msg.sender, _to, _token);
    }

    /**
     * Internal function to perform a ETH Withdrawal
     * @param to where the funds will be sent
     * @param amount address of the token withdraw (0x0 in case of Ether)
     */
    function _ethWithdrawal(address to, uint256 amount) internal {
        /* solhint-disable avoid-low-level-calls */
        (bool success, ) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    /**
     * Internal function to perform a Token Withdrawal
     * @param tokenAddress address of the token to transfer
     * @param to where the funds will be sent
     * @param amount address of the token withdraw (0x0 in case of Ether)
     */
    function _tokenWithdrawal(
        address tokenAddress,
        address to,
        uint256 amount
    ) internal {
        bool success;
        bytes memory data;

        // Check if the token is an ERC777
        bool isERC777 = _ERC1820_REGISTRY.getInterfaceImplementer(
            tokenAddress,
            keccak256("ERC777Token")
        ) != address(0x0)
            ? true
            : false;

        // In case that the token is an ERC777 we use send instead of transfer
        // Since an ERC777 is not forced to be ERC20 compatible
        if (isERC777) {
            /* solhint-disable avoid-low-level-calls */
            (success, data) = tokenAddress.call(
                abi.encodeWithSelector(_SEND_SIGNATURE, to, amount, "")
            );
        } else {
            /* solhint-disable avoid-low-level-calls */
            (success, data) = tokenAddress.call(
                abi.encodeWithSelector(_TRANSFER_SIGNATURE, to, amount)
            );
        }

        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "Token Transfer Failed"
        );
    }
}
