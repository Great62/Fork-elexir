// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/math/SafeMath.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/Counters.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC721/ERC721.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/security/ReentrancyGuard.sol";

import "./interfaces/IMintable.sol";
import "./YieldProductERC721.sol";
import "./interfaces/ITreasury.sol";
import "./ManaCooldown.sol";
import "./launch/EarlyToken.sol";
import "./launch/EarlyTokenRedeemer.sol";
import "./lib/LiteMath.sol";
import "./security/Managed.sol";

// The Fed is controlling the token emission, mint product listing, and the whole economy
contract Fed is Managed, ManaCooldown, LiteMath, ReentrancyGuard {
    using SafeMath for uint256;
    using Counters for Counters.Counter;

    uint64 public elexirFactor = 100; // 100 = 1

    Counters.Counter private mintIdCounter;

    struct Mint {
        uint256 id; //an id set by the caller
        IMintable tokenOnSale; //the mintable token to send/mint to the sender
        uint256 price; //the price in main token
        uint256 availableSupply; //assets availability for this sale
        uint256 initialSupply; //initial availability for this sale
        uint256 sold; //the number of assets sold during this sale
        uint256 manaCostPerToken; //how many mana you need to mint (cooldown)
        uint256 startAt; //timestamp seconds of the sale start date
        uint256 duration; //sale duration in seconds
        uint64 max;
        bool activated;
    }

    mapping(uint256 => Mint) public mintById;
    uint256[] public mintIDs;

    EarlyTokenRedeemer eTokenRedeemer;

    ERC20Burnable public token;
    ERC20Burnable public claimToken;
    ERC20Burnable public levelUpToken;

    uint64 public levelUpManaCost = 0;
    uint64 public claimManaCost = 50;

    mapping(YieldProductERC721 => bool) public claimableProducts;

    address public dao;
    address public operation;

    ITreasury treasury;

    uint256 public mintDaoFee = 0; //100 = 1%, 1300 = 13%
    uint256 public mintOperationFee = 0; //100 = 1%, 700 = 7%

    /* --------------------------
      Events.
      -------------------------- */

    event ProductClaimed(
        address indexed account,
        YieldProductERC721 indexed product,
        uint256 indexed tokenId,
        bool useClaimtoken,
        uint256 amount
    );

    event MintUpdated(
        uint256 indexed id,
        IMintable indexed tokenOnSale,
        uint256 price,
        uint256 availableSupply,
        uint256 manaCostPerToken,
        uint256 startAt,
        uint256 duration,
        uint64 max,
        bool activated
    );

    event MintRemoved(uint256 indexed id);
    event MintActivated(uint256 indexed id, bool activated);
    event UserMinted(uint256 indexed id, uint64 amount, bool payWithEarlyToken);
    event ElexirFactorUpdated(uint64 indexed elexirFactor);

    event ProductUpgraded(
        address indexed account,
        YieldProductERC721 indexed product,
        uint256 indexed tokenId,
        uint256 level
    );

    event ClaimableProductUpdated(
        YieldProductERC721 indexed product,
        bool claimable
    );
    event MintOperationFeeUpdated(uint256 fee);
    event MintDaoFeeUpdated(uint256 fee);
    event TreasuryUpdated(ITreasury indexed treasury);
    event OperationUpdated(address indexed operation);
    event DaoUpdated(address indexed dao);
    event ClaimTokenUpdated(ERC20Burnable indexed claimToken);
    event LevelUpTokenUpdated(ERC20Burnable indexed levelUpToken);
    event TokenUpdated(ERC20Burnable indexed token);
    event EarlyTokenRedeemerUpdated(EarlyTokenRedeemer indexed eTokenRedeemer);
    event LevelUpManaCostUpdated(uint64 cost);
    event ClaimManaCostUpdated(uint64 cost);

    /**
     * @dev Constructor.
     * @param _token The main token.
     * @param _eTokenRedeemer The early token redeemer contract so the Fed can redeem on behalf.
     * @param _claimToken The amount.
     * @param _levelUpToken The amount.
     * @param _dao The amount.
     * @param _operation The amount.
     * @param _treasury The treasury address.
     * @param _mintDaoFee The DAO fee.
     * @param _mintOperationFee The operation fee.
     * @param _initialManaAmount The initial mana amount. The x in x/100 MANA.
     * @param _manaPerHourDefault The default mana refill rate.
     */
    constructor(
        ERC20Burnable _token,
        EarlyTokenRedeemer _eTokenRedeemer,
        ERC20Burnable _claimToken,
        ERC20Burnable _levelUpToken,
        address _dao,
        address _operation,
        ITreasury _treasury,
        uint256 _mintDaoFee,
        uint256 _mintOperationFee,
        uint256 _initialManaAmount,
        uint256 _manaPerHourDefault
    ) ManaCooldown(_initialManaAmount, _manaPerHourDefault) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);

        setToken(_token);
        setEarlyTokenRedeemer(_eTokenRedeemer);
        setClaimToken(_claimToken);
        setLevelUpToken(_levelUpToken);

        setDao(_dao);
        setTreasury(_treasury);
        setOperation(_operation);

        setMintDaoFee(_mintDaoFee);
        setMintOperationFee(_mintOperationFee);
    }

    /* --------------------------
      Modifiers.
      -------------------------- */

    modifier productClaimable(YieldProductERC721 _product) {
        require(
            claimableProducts[_product] == true,
            "Fed:PRODUCT_IS_NOT_CLAIMABLE"
        );
        _;
    }

    /**
     * @dev Mint the main token to the given account by asking the treasury to do it using the excess reserves.
     * @param _to The recipient.
     * @param _amount The amount.
     */
    function _payWithTreasuryExcessReserves(address _to, uint256 _amount)
        internal
    {
        treasury.mint(_to, _amount);
    }

    /**
     * @dev Mint the main token to the the MagicFed by asking the treasury to do it using the excess reserves.
     * @param _amount The amount.
     */
    function mintForRewards(uint256 _amount) public onlyRole(MANAGER_ROLE) {
        _payWithTreasuryExcessReserves(address(this), _amount);
    }

    /**
     * @dev Manager function to create or update a mint.
     * @param _id Value to test.
     * @param _tokenOnSale Value to test.
     * @param _price Value to test.
     * @param _availableSupply Value to test.
     * @param _manaCostPerToken Mana cost by purchased token.
     * @param _startAt The start date of the mint.
     * @param _duration The duration of the mint.
     * @param _max Max token to mint by transaction.
     */
    function setMint(
        uint256 _id,
        IMintable _tokenOnSale,
        uint256 _price,
        uint256 _availableSupply,
        uint256 _manaCostPerToken,
        uint256 _startAt,
        uint256 _duration,
        uint64 _max,
        bool _activated
    ) public onlyRole(MANAGER_ROLE) {
        mintById[_id] = Mint({
            id: _id,
            tokenOnSale: _tokenOnSale,
            price: _price,
            availableSupply: _availableSupply,
            initialSupply: _availableSupply,
            sold: mintById[_id].sold,
            manaCostPerToken: _manaCostPerToken,
            startAt: _startAt,
            duration: _duration,
            max: _max,
            activated: _activated
        });

        (bool found, ) = isMintExists(_id);
        if (!found) {
            mintIDs.push(_id);
        }

        emit MintUpdated(
            _id,
            _tokenOnSale,
            _price,
            _availableSupply,
            _manaCostPerToken,
            _startAt,
            _duration,
            _max,
            _activated
        );
    }

    /**
     * @dev Manager function to activate or deactivate a mint.
     * @param _id The mint id.
     * @param _activated Activate or not.
     */
    function activateMint(uint256 _id, bool _activated)
        public
        onlyRole(MANAGER_ROLE)
    {
        Mint storage _mint = mintById[_id];
        require(
            address(_mint.tokenOnSale) != address(0),
            "Fed:MINT_DOES_NOT_EXISTS"
        );
        _mint.activated = _activated;

        emit MintActivated(_id, _activated);
    }

    /**
     * @dev Helper function to remove a mint.
     * @param _id Mint id to remove.
     */
    function removeMint(uint256 _id) public onlyRole(MANAGER_ROLE) {
        (bool found, uint256 i) = isMintExists(_id);

        if (found) {
            require(i < mintIDs.length);
            mintIDs[i] = mintIDs[mintIDs.length - 1];
            mintIDs.pop();

            delete mintById[_id];
        }

        emit MintRemoved(_id);
    }

    /**
     * @dev View function to list mint IDs as array instead of the default getter.
     */
    function getMintIDs() public view returns (uint256[] memory) {
        return mintIDs;
    }

    /**
     * @dev Helper function to test wether a value is already in mintIDs.
     * @param _value Value to test.
     */
    function isMintExists(uint256 _value)
        internal
        view
        returns (bool, uint256)
    {
        for (uint256 i = 0; i < mintIDs.length; i++) {
            if (mintIDs[i] == _value) {
                return (true, i);
            }
        }
        return (false, 0);
    }

    /**
     * @dev Mint the desired asset by specifying the mintId and amount. Paying with EarlyToken is possible.
     * @param _id The Mint id.
     * @param _amount The amount of assets to mint.
     * @param _payWithEarlyToken Wether the user want to pay with an early token (presale token).
     */
    function mint(
        uint256 _id,
        uint64 _amount,
        bool _payWithEarlyToken
    ) external nonReentrant returns (bool) {
        Mint storage _mint = mintById[_id];

        require(_mint.activated == true, "Fed:MINT_NOT_ACTIVATED");
        require(_mint.startAt < block.timestamp, "Fed:MINT_NOT_STARTED"); //check mint is open
        require(
            _mint.startAt + _mint.duration > block.timestamp,
            "Fed:MINT_FINISHED"
        ); //check mint is not finish

        require(_mint.availableSupply > 0, "Fed:MINT_SOLDOUT"); //check mint is not soldout
        require(
            _mint.availableSupply >= _amount,
            "Fed:MINT_AMOUNT_ABOVE_AVAILABLE_SUPPLY"
        ); //check mint is not soldout
        require(_amount <= _mint.max, "Fed:MINT_AMOUNT_ABOVE_MAX"); //check the max mintable by transaction

        address sender = _msgSender();

        // check mana cost (we do not use the manaCost modifier here because the cost is dynamic, set in the Mint structure)
        uint256 toPayManaAmount = _mint.manaCostPerToken * _amount;

        (uint256 availableMana, ) = availableMana(sender);
        require(availableMana >= toPayManaAmount, "Fed:NOT_ENOUGH_MANA");

        uint256 toPayAmount = _mint.price * _amount;

        if (_payWithEarlyToken) {
            require(
                eTokenRedeemer.balanceOfEarlyToken(sender) > toPayAmount,
                "Fed:EARLY_TOKEN_BALANCE_TOO_LOW"
            ); //we check if the user has enough EarlyToken.

            eTokenRedeemer.redeemOnBehalf(sender, address(this), toPayAmount); //we redeem the EarlyToken on behalf of the user. The Fed (this contract) receives the Redeemed Token instead of the user.
        } else {
            require(
                token.balanceOf(sender) > toPayAmount,
                "Fed:BALANCE_TOO_LOW"
            );
            require(
                token.transferFrom(sender, address(this), toPayAmount),
                "Fed:TRANSFER_FAILED"
            ); //transfer the right amount of principle to pay the mint
        }

        uint256 daoAmount = toPayAmount.mul(mintDaoFee).div(10000);
        uint256 operationAmount = toPayAmount.mul(mintOperationFee).div(10000);

        require(token.transfer(dao, daoAmount), "Fed:TRANSFER_FAILED");
        require(
            token.transfer(operation, operationAmount),
            "Fed:TRANSFER_FAILED"
        );

        uint256 rewardAmount = toPayAmount.sub(daoAmount).sub(operationAmount);
        token.burn(rewardAmount); //we burn the remaining token so that the treasury's excess reserves increase

        uint256 mintedAmount = _mint.tokenOnSale.mint(sender, _amount); //do the token mint

        require(mintedAmount == _amount, "Fed:MINT_FAILED");
        _mint.availableSupply -= mintedAmount; //decrease available token

        // consume the mana cost
        _consumeMana(sender, toPayManaAmount);

        emit UserMinted(_id, _amount, _payWithEarlyToken);
        return true;
    }

    /**
     * @dev Quote the price (claim token as unit) to claim a product.
     * @param _product The Product.
     * @param _tokenId The product token id.
     */
    function quoteClaimProduct(YieldProductERC721 _product, uint256 _tokenId)
        public
        view
        returns (uint32)
    {
        return uint32(sqrt(_product.getLevel(_tokenId) * 100) / 10); //cost to claim is the integer square root of level isqrt(level)
    }

    /**
     * @dev Claim a product. This costs MANA.
     * @param _product The Product.
     * @param _tokenId The product token id.
     * @param _useClaimToken Does the caller want to use claim token ? If not, the product is burned.
     */
    function claimProduct(
        YieldProductERC721 _product,
        uint256 _tokenId,
        bool _useClaimToken
    )
        external
        nonReentrant
        productClaimable(_product)
        manaCost(claimManaCost)
        returns (bool)
    {
        address sender = _msgSender();
        require(_product.ownerOf(_tokenId) == sender, "Fed:NOT_OWNER");

        YieldProductERC721.ProductComputedAtInfo
            memory productInfo = getProductInfoNow(_product, _tokenId); //product valuation
        uint256 value = productInfo.valueAt;

        require(value > 0, "Fed:NO_TOKEN_TO_CLAIM");

        // claimBooster = true means free claim!!
        if (!productInfo.product.claimBooster) {
            // pay with claim token to not destroy the product
            if (_useClaimToken) {
                uint32 toBurnAmount = quoteClaimProduct(_product, _tokenId);

                require(
                    claimToken.balanceOf(sender) >= toBurnAmount,
                    "Fed:CLAIM_TOKEN_BALANCE_TOO_LOW"
                );
                claimToken.burnFrom(sender, toBurnAmount);
            } else {
                // destroy the product if claimed without a claim token.
                _product.burn(_tokenId);
            }
        }

        // update product on-chain data
        _product.productClaimed(_tokenId, block.timestamp, value);

        // finally pay the account asking for a claim using treasury excess reserves
        _payWithTreasuryExcessReserves(sender, value);

        emit ProductClaimed(sender, _product, _tokenId, _useClaimToken, value);
        return true;
    }

    /**
     * @dev List product info by ID. Info contains computed value like dailyReturn and value now.
     * @param _product The Product.
     * @param _tokenId The product token id.
     */
    function getProductInfoNow(YieldProductERC721 _product, uint256 _tokenId)
        public
        view
        returns (YieldProductERC721.ProductComputedAtInfo memory)
    {
        return
            _product.getProductInfoAt(_tokenId, block.timestamp, elexirFactor);
    }

    /**
     * @dev List product info by ID. Info contains computed value like dailyReturn and value at the specified time.
     * @param _product The Product.
     * @param _tokenId The product token id.
     */
    function getProductInfoAt(
        YieldProductERC721 _product,
        uint256 _tokenId,
        uint256 _at
    ) external view returns (YieldProductERC721.ProductComputedAtInfo memory) {
        return _product.getProductInfoAt(_tokenId, _at, elexirFactor);
    }

    /**
     * @dev List the products info by IDs. Info contains computed value like dailyReturn and value at different moment in time.
     * @param _product The Product.
     * @param _tokensId The product token id.
     */
    function getProductsInfo(
        YieldProductERC721 _product,
        uint256[] memory _tokensId
    ) external view returns (YieldProductERC721.ProductComputedInfo[] memory) {
        return _product.getProductsInfo(_tokensId, elexirFactor);
    }

    /**
     * @dev Quote the price (level up token as unit) to level up a product.
     * @param _product The Product.
     * @param _tokenId The product token id.
     */
    function quoteLevelUpProduct(YieldProductERC721 _product, uint256 _tokenId)
        public
        view
        returns (uint32)
    {
        YieldProductERC721.Product memory product = _product.getProduct(
            _tokenId
        );
        if (product.levelUpBooster) {
            return uint32(product.level) / 2; //booster reduces the cost (cost/2)
        } else {
            return uint32(product.level); //cost to levelup is the expected level itself (expected level - 1 = current level)
        }
    }

    /**
     * @dev Upgrade a product level. This costs MANA.
     * @param _product The Product.
     * @param _tokenId The product token id.
     */
    function levelUpProduct(YieldProductERC721 _product, uint256 _tokenId)
        external
        nonReentrant
        manaCost(levelUpManaCost)
        returns (uint256)
    {
        address sender = _msgSender();

        uint32 toBurnAmount = quoteLevelUpProduct(_product, _tokenId);

        require(
            levelUpToken.balanceOf(sender) >= toBurnAmount,
            "Fed:LEVELUP_TOKEN_BALANCE_TOO_LOW"
        );
        levelUpToken.burnFrom(sender, toBurnAmount); //transfer the right amount of principle to pay

        emit ProductUpgraded(
            sender,
            _product,
            _tokenId,
            _product.getLevel(_tokenId)
        );

        return _product.incrementLevel(_tokenId);
    }

    /**
     * @dev Set claim mana cost.
     * @param _levelUpManaCost The new claim mana cost value.
     */
    function setLevelUpManaCost(uint64 _levelUpManaCost)
        public
        onlyRole(MANAGER_ROLE)
    {
        levelUpManaCost = _levelUpManaCost;
        emit LevelUpManaCostUpdated(_levelUpManaCost);
    }

    /**
     * @dev Set claim mana cost.
     * @param _claimManaCost The new claim mana cost value.
     */
    function setClaimManaCost(uint64 _claimManaCost)
        public
        onlyRole(MANAGER_ROLE)
    {
        claimManaCost = _claimManaCost;
        emit ClaimManaCostUpdated(_claimManaCost);
    }

    /**
     * @dev Set a product as claimable. Must be admin.
     * @param _product The Product address.
     * @param _claimable Claimable or not.
     */
    function setProductClaimable(YieldProductERC721 _product, bool _claimable)
        external
        onlyRole(MANAGER_ROLE)
    {
        claimableProducts[_product] = _claimable;
        emit ClaimableProductUpdated(_product, _claimable);
    }

    /**
     * @dev The admin can set the ElexirFactor.
     * @param _elexirFactor The ElexirFactor.
     */
    function setElexirFactor(uint64 _elexirFactor)
        external
        onlyRole(MANAGER_ROLE)
    {
        elexirFactor = _elexirFactor;
        emit ElexirFactorUpdated(_elexirFactor);
    }

    /**
     * @dev Manager function to set the mintDaoFee.
     * @param _mintDaoFee The DAO fee on each mint.
     */
    function setMintDaoFee(uint256 _mintDaoFee) public onlyRole(MANAGER_ROLE) {
        mintDaoFee = _mintDaoFee;
        emit MintDaoFeeUpdated(_mintDaoFee);
    }

    /**
     * @dev Manager function to set the mintOperationFee.
     * @param _mintOperationFee The Operation fee on each mint.
     */
    function setMintOperationFee(uint256 _mintOperationFee)
        public
        onlyRole(MANAGER_ROLE)
    {
        mintOperationFee = _mintOperationFee;
        emit MintOperationFeeUpdated(_mintOperationFee);
    }

    /**
     * @dev Set the treasury. Must be admin.
     * @param _treasury The new treasury address.
     */
    function setTreasury(ITreasury _treasury)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    /**
     * @dev Set the level up token. Must be admin.
     * @param _levelUpToken The level up token.
     */
    function setLevelUpToken(ERC20Burnable _levelUpToken)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        levelUpToken = _levelUpToken;
        emit LevelUpTokenUpdated(_levelUpToken);
    }

    /**
     * @dev Set the main token. Must be admin.
     * @param _token The new main token.
     */
    function setToken(ERC20Burnable _token)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        token = _token;
        emit TokenUpdated(_token);
    }

    /**
     * @dev Set early token redeemer contract. Must be admin.
     * @param _eTokenRedeemer The new early token redeemer.
     */
    function setEarlyTokenRedeemer(EarlyTokenRedeemer _eTokenRedeemer)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        eTokenRedeemer = _eTokenRedeemer;
        emit EarlyTokenRedeemerUpdated(_eTokenRedeemer);
    }

    /**
     * @dev Set the claim token. Must be admin.
     * @param _claimToken The new claim token.
     */
    function setClaimToken(ERC20Burnable _claimToken)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        claimToken = _claimToken;
        emit ClaimTokenUpdated(_claimToken);
    }

    /**
     * @dev Set operation. Must be admin.
     * @param _operation The new operation address.
     */
    function setOperation(address _operation)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        operation = _operation;
        emit OperationUpdated(_operation);
    }

    /**
     * @dev Set dao. Must be admin.
     * @param _dao The new dao address.
     */
    function setDao(address _dao) public onlyRole(DEFAULT_ADMIN_ROLE) {
        dao = _dao;
        emit DaoUpdated(_dao);
    }

    /**
     * @dev Boost the given IDs. This action can not be undone! A boosted cauldron remains booster forever.
     * @param _product The token IDs.
     * @param _tokensId The token IDs.
     * @param _levelUp LevelUp booster.
     * @param _claim Claim booster.
     * @param _reward Reward booster.
     */
    function boost(
        YieldProductERC721 _product,
        uint256[] memory _tokensId,
        bool _levelUp,
        bool _claim,
        bool _reward
    ) public onlyRole(MANAGER_ROLE) {
        return _product.boost(_tokensId, _levelUp, _claim, _reward);
    }

    /**
     * @dev Recover any ERC20 token. Must be admin.
     * @param _token The token contract address
     * @param _to Beneficiary.
     */
    function recoverERC20(ERC20 _token, address _to)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _token.transfer(_to, _token.balanceOf(address(this)));
    }

    /**
     * @dev Recover AVAX. Must be admin.
     * @param _to Beneficiary.
     */
    function recoverAVAX(address payable _to)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _to.transfer(address(this).balance);
    }
}
