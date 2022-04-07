// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.2;

import "./EarlyToken.sol";

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/math/SafeMath.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/AccessControl.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/security/ReentrancyGuard.sol";

contract EarlyTokenRedeemer is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address public vestingToken;
    EarlyToken public eToken;

    event Withdrawal(
        address indexed addr,
        uint256 amountFromInitial,
        uint256 totalAmount
    );

    uint256 public totalAmountWithdrawn;
    uint256 public totalAmountDeposited;
    uint256 public totalAmountWithdrawnFromAdded;

    uint256 public startDate;
    uint256 public periodLength;
    uint256 public numberOfPeriods;

    struct ReceiverInfo {
        uint256 amountWithdrawn;
        uint256 redeemedEarlyTokenAmount;
        uint256 initialEarlyTokenAmount;
        bool isRegistered;
    }

    mapping(address => ReceiverInfo) public receiverInfoMap;

    // Roles
    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");

    constructor(
        address _vestingToken,
        EarlyToken _eToken,
        uint256 _startDate,
        uint256 _periodLength,
        uint256 _numberOfPeriods
    ) {
        vestingToken = _vestingToken;
        eToken = EarlyToken(_eToken);
        startDate = _startDate;
        periodLength = _periodLength;
        numberOfPeriods = _numberOfPeriods;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /* --------------------------
      Public functions
      -------------------------- */

    /**
     * @dev Main public function that allows the user to redeem.
     */
    function redeem() public nonReentrant {
        address user = msg.sender;
        return _redeem(user, user, true, 0);
    }

    /**
     * @dev Returns the balance of Early Token for the given account. Helper for the Fed contract.
     * @param _account The account.
     */
    function balanceOfEarlyToken(address _account)
        public
        view
        returns (uint256)
    {
        return eToken.balanceOf(_account);
    }

    /**
     * @dev Remaining amount to withdraw for the caller.
     */
    function remainingToWithdraw() public view returns (uint256) {
        uint256 senderEarlyTokenBalance = eToken.balanceOf(msg.sender);
        return
            computeAmount(senderEarlyTokenBalance).div(10**eToken.decimals());
    }

    /**
     * @dev The percent vested from start date.
     */
    function percentVested() public view returns (uint256 percentVested_) {
        uint256 secondsSinceStart = block.timestamp.sub(startDate);

        if (secondsSinceStart > 0) {
            percentVested_ = secondsSinceStart.mul(10000).div(periodLength).div(
                    numberOfPeriods
                );
        } else {
            percentVested_ = 0;
        }
        if (percentVested_ > 10000) percentVested_ = 10000;
    }

    /**
     * @dev The remaining EarlyToken that can be redeemable.
     */
    function currentlyRedeemable() public view returns (uint256) {
        ReceiverInfo memory userInfo = receiverInfoMap[msg.sender];

        uint256 eTokenBalance = userInfo.isRegistered
            ? userInfo.initialEarlyTokenAmount
            : eToken.balanceOf(msg.sender);

        uint256 redeemableAmountTotal = percentVested().mul(eTokenBalance).div(
            10000
        );

        if (redeemableAmountTotal < userInfo.redeemedEarlyTokenAmount) {
            return 0;
        }

        return redeemableAmountTotal.sub(userInfo.redeemedEarlyTokenAmount);
    }

    /* --------------------------
      Private functions
      -------------------------- */

    /**
     * @dev Redeem EarlyToken against Vesting token.
     * @param _user Value to test.
     * @param _beneficiary The beneficiary of Vesting token.
     * @param _vesting Activate vesting?
     * @param _amount The amount to redeem.
     */
    function _redeem(
        address _user,
        address _beneficiary,
        bool _vesting,
        uint256 _amount
    ) private {
        if (_vesting) {
            require(block.timestamp >= startDate, "REDEEM_NOT_STARTED");
        }

        ReceiverInfo memory userInfo = receiverInfoMap[_user];

        if (!userInfo.isRegistered) {
            userInfo = ReceiverInfo({
                amountWithdrawn: 0,
                redeemedEarlyTokenAmount: 0,
                initialEarlyTokenAmount: eToken.balanceOf(_user),
                isRegistered: true
            });
            receiverInfoMap[_user] = userInfo;
        }

        uint256 redeemableAmountFromInitial = 0;

        // linear vesting activated
        if (_vesting) {
            uint256 secondsSinceStart = block.timestamp.sub(startDate);
            uint256 periodsSinceStart = secondsSinceStart / periodLength;
            if (periodsSinceStart > numberOfPeriods) {
                periodsSinceStart = numberOfPeriods;
            }

            redeemableAmountFromInitial = currentlyRedeemable();
            require(redeemableAmountFromInitial > 0, "NO_REDEEMABLE_TOKEN");

            // no linear vesting, the caller can redeem the desired amount (this is used by the magicfed)
        } else {
            require(
                _amount <=
                    userInfo.initialEarlyTokenAmount.sub(
                        userInfo.redeemedEarlyTokenAmount
                    ),
                "NO_REDEEMABLE_TOKEN"
            );
            redeemableAmountFromInitial = _amount;
        }

        uint256 withdrawableAmount = computeAmount(redeemableAmountFromInitial);

        eToken.redeem(_user, redeemableAmountFromInitial);

        require(
            IERC20(vestingToken).transfer(_beneficiary, withdrawableAmount),
            "VESTING_TOKEN_TRANSFER_FAILED"
        );

        receiverInfoMap[_user] = ReceiverInfo({
            amountWithdrawn: userInfo.amountWithdrawn.add(withdrawableAmount),
            redeemedEarlyTokenAmount: userInfo.redeemedEarlyTokenAmount.add(
                redeemableAmountFromInitial
            ),
            initialEarlyTokenAmount: userInfo.initialEarlyTokenAmount,
            isRegistered: true
        });

        totalAmountWithdrawn += withdrawableAmount;
        totalAmountWithdrawnFromAdded += redeemableAmountFromInitial;

        emit Withdrawal(_user, redeemableAmountFromInitial, withdrawableAmount);
    }

    /**
     * @dev Compute EarlyToken:VestingToken ratio.
     * @param _amount The amount to redeem.
     */
    function computeAmount(uint256 _amount) internal pure returns (uint256) {
        return _amount;
    }

    /* --------------------------
      REDEEMER_ROLE functions
      -------------------------- */

    /**
     * @dev Redeem on behalf of the user.
     * @param _user Value to test.
     * @param _beneficiary The beneficiary of Vesting token.
     * @param _amount The amount to redeem.
     */
    function redeemOnBehalf(
        address _user,
        address _beneficiary,
        uint256 _amount
    ) public onlyRole(REDEEMER_ROLE) {
        return _redeem(_user, _beneficiary, false, _amount);
    }

    /**
     * @dev Set the vesting start date. Must be admin.
     * @param _startDate The start date.
     */
    function setStartDate(uint256 _startDate)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(block.timestamp < startDate, "VESTING_ALREADY_STARTED");
        startDate = _startDate;
    }

    /**
     * @dev Set the period length. Must be admin.
     * @param _length Length.
     */
    function setPeriodLength(uint256 _length)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(block.timestamp < startDate, "VESTING_ALREADY_STARTED");
        periodLength = _length;
    }

    /**
     * @dev Set the number of periods. Must be admin.
     * @param _number Periods.
     */
    function setNumberOfPeriods(uint256 _number)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(block.timestamp < startDate, "VESTING_ALREADY_STARTED");
        numberOfPeriods = _number;
    }

    /**
     * @dev Deposit the vesting token. Must be admin.
     * @param _amount Number of tokens to be sent
     */
    function depositVestingToken(uint256 _amount)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        IERC20(vestingToken).transferFrom(msg.sender, address(this), _amount);
        totalAmountDeposited += _amount;
    }

    /**
     * @dev Recover any ERC20 token. Must be admin.
     * @param _tokenAddress The token contract address
     * @param _tokenAmount Number of tokens to be sent
     */
    function recoverERC20(
        IERC20 _tokenAddress,
        uint256 _tokenAmount,
        address _to
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _tokenAddress.transfer(_to, _tokenAmount);
    }
}
