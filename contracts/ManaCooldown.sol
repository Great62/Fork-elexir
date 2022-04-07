// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "./security/Managed.sol";

contract ManaCooldown is Managed {
    mapping(address => uint256) public manaStartByAddress;
    mapping(address => uint256) public manaPerHourByAddress;

    uint256 initialManaAmount = 100;
    uint256 manaPerHourDefault = 10000;

    uint64 public constant MANA_PER_HOUR_PRECISION = 100;
    uint32 public constant MANA_MAX = 100;
    uint32 public constant MANA_MIN = 0;

    /**
     * @dev Constructor.
     * @param _initialManaAmount The mana initial amount.
     * @param _manaPerHourDefault The mana per hour default value.
     */
    constructor(uint256 _initialManaAmount, uint256 _manaPerHourDefault) {
        initialManaAmount = _initialManaAmount;
        manaPerHourDefault = _manaPerHourDefault;
    }

    /* -------------------
        Modifiers.
    ------------------- */

    modifier manaCost(uint256 _cost) {
        address sender = msg.sender;
        (uint256 _availableMana, ) = availableMana(sender);
        require(_availableMana >= _cost, "NOT_ENOUGH_MANA");
        _;
        _consumeMana(sender, _cost);
    }

    /**
     * @dev Consume mana for the given account.
     * @param _account The account to be consumed.
     * @param _amount The amount to consume.
     */
    function _consumeMana(address _account, uint256 _amount)
        internal
        returns (uint256, uint256)
    {
        uint256 _manaStart = manaStart(_account);
        uint256 _manaPerHour = manaPerHour(_account);

        uint256 manaTimeCostSeconds = (_amount *
            MANA_PER_HOUR_PRECISION *
            1 hours) / _manaPerHour; //convert amount to time

        manaStartByAddress[_account] = _manaStart + manaTimeCostSeconds; //moving time forward = reducing the mana

        uint256 nowTs = block.timestamp;
        if (manaStartByAddress[_account] > nowTs) {
            manaStartByAddress[_account] = nowTs;
        }

        return availableMana(_account);
    }

    /**
     * @dev Get the mana start value or max or default.
     * @param _account The account.
     */
    function manaStart(address _account) public view returns (uint256) {
        uint256 _manaStart = manaStartByAddress[_account];
        uint256 _manaPerHour = manaPerHour(_account);

        if (_manaStart == 0) {
            return
                block.timestamp -
                (initialManaAmount * MANA_PER_HOUR_PRECISION * 1 hours) /
                _manaPerHour;
        } else {
            uint256 maxManaStart = block.timestamp -
                (MANA_MAX * MANA_PER_HOUR_PRECISION * 1 hours) /
                _manaPerHour;

            if (_manaStart < maxManaStart) {
                _manaStart = maxManaStart;
            }

            return _manaStart;
        }
    }

    /**
     * @dev Get the mana per hour for the given account or the default value.
     * @param _account The account.
     */
    function manaPerHour(address _account) public view returns (uint256) {
        uint256 _manaPerHour = manaPerHourByAddress[_account];
        if (_manaPerHour == 0) {
            return manaPerHourDefault;
        } else {
            return _manaPerHour;
        }
    }

    /**
     * @dev Get available mana for the given account.
     * @param _account The main token.
     */
    function availableMana(address _account)
        public
        view
        returns (uint256, uint256)
    {
        uint256 _manaStart = manaStart(_account);
        uint256 _manaPerHour = manaPerHour(_account);

        uint256 mana = ((block.timestamp - _manaStart) * _manaPerHour) /
            (MANA_PER_HOUR_PRECISION * 1 hours);

        if (mana > MANA_MAX) {
            mana = MANA_MAX;
        }

        if (mana < MANA_MIN) {
            mana = MANA_MIN;
        }

        return (mana, MANA_MAX);
    }

    /**
     * @dev Manager can set the mana per hour.
     * @param _manaPerHourDefault Mana per hour refill.
     */
    function setManaPerHourDefault(uint256 _manaPerHourDefault)
        public
        onlyRole(MANAGER_ROLE)
    {
        manaPerHourDefault = _manaPerHourDefault;
    }

    /**
     * @dev Manager can change the mana per hour for a specific account.
     * @param _account The account.
     * @param _manaPerHour Mana per hour refill.
     */
    function setManaPerHour(address _account, uint256 _manaPerHour)
        public
        onlyRole(MANAGER_ROLE)
    {
        manaPerHourByAddress[_account] = _manaPerHour;
    }
}
