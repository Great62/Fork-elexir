// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC721/ERC721.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/security/Pausable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/AccessControl.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/Counters.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/math/SafeMath.sol";

import "./interfaces/IMintable.sol";
import "./lib/InterestUtils.sol";
import "./security/Managed.sol";

abstract contract YieldProductERC721 is
    ERC721,
    Pausable,
    Managed,
    ERC721Burnable,
    ERC721Enumerable,
    IMintable
{
    using Strings for uint256;
    using Address for address;

    using Counters for Counters.Counter;

    Counters.Counter private _tokenIdCounter;

    uint256 public baseDailyReturn;

    string public baseURI;
    string public baseExtension = ".json";
    string public notRevealedUri;
    bool public revealed = false;

    struct Product {
        uint256 id; //id matching the token id
        uint256 mintedAt; //time when the product was minted / created
        uint256 lastClaimedAt; //last time reward was claimed
        uint256 totalClaimed; //claimable profit, number of token
        uint256 baseDailyReturn; //units = the native token (eg ELXR)
        uint32 level; //level = increase the baseDailyReturn
        bool levelUpBooster;
        bool claimBooster;
        bool rewardBooster;
    }

    struct ProductComputedInfo {
        Product product;
        uint256 dailyReturn;
        uint256 valueNow;
        uint256 value1Month;
        uint256 value1Year;
        uint256 nowTs;
    }

    struct ProductComputedAtInfo {
        Product product;
        uint256 dailyReturn;
        uint256 valueAt;
        uint256 at;
    }

    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _owners;
    mapping(uint256 => Product) private _productById;
    mapping(address => uint256[]) private _productsByOwner;

    uint256 public constant MAX_LEVEL = 100;
    uint256 public constant MIN_LEVEL = 1;

    uint256 public maxSupply;

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _baseDailyReturn,
        uint256 _maxSupply
    ) ERC721(_name, _symbol) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        baseDailyReturn = _baseDailyReturn;
        maxSupply = _maxSupply;
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal override(ERC721, ERC721Enumerable) whenNotPaused {
        super._beforeTokenTransfer(from, to, tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @dev Override tokenURI with a reveal mechanism.
     * @param tokenId The token Id.
     */
    function tokenURI(uint256 tokenId)
        public
        view
        virtual
        override
        returns (string memory)
    {
        require(_exists(tokenId), "YieldProductERC721:TOKEN_DOES_NOT_EXISTS");

        if (revealed == false) {
            return notRevealedUri;
        }

        string memory currentBaseURI = baseURI;
        return
            bytes(currentBaseURI).length > 0
                ? string(
                    abi.encodePacked(
                        currentBaseURI,
                        tokenId.toString(),
                        baseExtension
                    )
                )
                : "";
    }

    /* --------------------------
      Admin functions
      -------------------------- */

    /**
     * @dev Reveal all tokens by setting the new URI.
     */
    function reveal() public onlyRole(DEFAULT_ADMIN_ROLE) {
        revealed = true;
    }

    /**
     * @dev Set the unrevealed URI.
     * @param _notRevealedURI The unrevealed URI.
     */
    function setNotRevealedURI(string memory _notRevealedURI)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        notRevealedUri = _notRevealedURI;
    }

    /**
     * @dev Set the baseURI.
     * @param _newBaseURI The base URI.
     */
    function setBaseURI(string memory _newBaseURI)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        baseURI = _newBaseURI;
    }

    /**
     * @dev Set the base extension URI.
     * @param _newBaseExtension The base extension.
     */
    function setBaseExtension(string memory _newBaseExtension)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        baseExtension = _newBaseExtension;
    }

    /**
     * @dev Pause the token transfers.
     */
    function pause() public onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause the token transfers.
     */
    function unpause() public onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /* --------------------------
      Manager functions
      -------------------------- */

    /**
     * @dev Mint one token.
     * @param _to The minted token recipient.
     */
    function mintOne(address _to) public onlyRole(MANAGER_ROLE) {
        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();

        require(
            totalSupply() < maxSupply,
            "YieldProductERC721:ABOVE_MAX_SUPPLY"
        );

        _safeMint(_to, tokenId);

        _productById[tokenId] = Product({
            id: tokenId,
            mintedAt: block.timestamp,
            lastClaimedAt: block.timestamp,
            totalClaimed: 0,
            baseDailyReturn: baseDailyReturn,
            level: 1,
            levelUpBooster: false,
            claimBooster: false,
            rewardBooster: false
        });

        _owners[tokenId] = _to;
        _productsByOwner[_to].push(tokenId);
        _balances[_to] += 1;
    }

    /**
     * @dev Mint many tokens.
     * @param _to The mitned token recipient.
     * @param _amount The number of tokens to mint.
     */
    function mint(address _to, uint256 _amount)
        public
        override
        onlyRole(MANAGER_ROLE)
        returns (uint256)
    {
        uint256 minted = 0;
        for (uint256 i = 0; i < _amount; i++) {
            mintOne(_to);
            minted += 1;
        }
        return minted;
    }

    /**
     * @dev Set the level.
     * @param _tokenId The token ID.
     * @param _level The level.
     */
    function setLevel(uint256 _tokenId, uint32 _level)
        public
        onlyRole(MANAGER_ROLE)
    {
        require(_level >= MIN_LEVEL, "YieldProductERC721:BELOW_MAX_LEVEL");
        require(_level <= MAX_LEVEL, "YieldProductERC721:ABOVE_MAX_LEVEL");

        Product storage product = _productById[_tokenId];
        product.level = _level;
    }

    /**
     * @dev Boost the given IDs. This action can not be undone! A boosted cauldron remains booster forever.
     * @param _tokensId The token IDs.
     * @param _levelUp LevelUp booster.
     * @param _claim Claim booster.
     * @param _reward Reward booster.
     */
    function boost(
        uint256[] memory _tokensId,
        bool _levelUp,
        bool _claim,
        bool _reward
    ) public onlyRole(MANAGER_ROLE) {
        for (uint256 i = 0; i < _tokensId.length; i++) {
            uint256 productId = _tokensId[i];
            if (_exists(productId)) {
                Product storage product = _productById[productId];
                if (_levelUp) {
                    product.levelUpBooster = true;
                }
                if (_claim) {
                    product.claimBooster = true;
                }
                if (_reward) {
                    product.rewardBooster = true;
                }
            }
        }
    }

    /**
     * @dev Increment the level for the given product ID.
     * @param _tokenId The token ID.
     */
    function incrementLevel(uint256 _tokenId)
        public
        onlyRole(MANAGER_ROLE)
        returns (uint32)
    {
        uint32 levelUpTo = _productById[_tokenId].level + 1;
        setLevel(_tokenId, levelUpTo);
        return levelUpTo;
    }

    /**
     * @dev Decrement the level for the given product ID.
     * @param _tokenId The token ID.
     */
    function decrementLevel(uint256 _tokenId)
        public
        onlyRole(MANAGER_ROLE)
        returns (uint32)
    {
        uint32 levelDownTo = _productById[_tokenId].level - 1;
        setLevel(_tokenId, levelDownTo);
        return levelDownTo;
    }

    /**
     * @dev Set product claim related on-chain data.
     * @param _tokenId The token ID.
     * @param _claimedAt The claim timestamp.
     * @param _claimedAmount The amount claimed.
     */
    function productClaimed(
        uint256 _tokenId,
        uint256 _claimedAt,
        uint256 _claimedAmount
    ) public onlyRole(MANAGER_ROLE) {
        Product storage product = _productById[_tokenId];
        product.lastClaimedAt = _claimedAt;
        product.totalClaimed += _claimedAmount;
    }

    /* --------------------------
      Public/external/view functions
      -------------------------- */

    /**
     * @dev Get product.
     * @param _tokenId The token ID.
     */
    function getProduct(uint256 _tokenId) public view returns (Product memory) {
        Product memory product = _productById[_tokenId];
        return product;
    }

    /**
     * @dev Get the level for the given product ID.
     * @param _tokenId The token ID.
     */
    function getLevel(uint256 _tokenId) public view returns (uint32) {
        Product memory product = _productById[_tokenId];
        return product.level;
    }

    /**
     * @dev Compute the product daily return given the ElexirFactor, product base daily return, level and rewardBooster
     * @param _baseDailyReturn The product base daily return.
     * @param _elexirFactor The Elexir Factor.
     * @param _productLevel The product level.
     */
    function _computeProductDailyReturn(
        uint256 _baseDailyReturn,
        uint256 _elexirFactor,
        uint256 _productLevel,
        bool boosted
    ) internal pure returns (uint256) {
        uint256 dailyReturn = (_baseDailyReturn *
            _elexirFactor *
            _productLevel) / 100; // 100 = elexirRate precision, 50 == 0.5 ; 100 = 1
        return boosted ? dailyReturn * 2 : dailyReturn; //booster multiply reward by 2
    }

    /**
     * @dev Compute the product daily return given the ElexirFactor, product base daily return and level.
     * @param _dailyReturn The product daily return.
     * @param _claimTime The claim time resolution in seconds.
     * @param _from The return start date.
     * @param _at The return end date.
     */
    function _computeProductValueAt(
        uint256 _dailyReturn,
        uint256 _claimTime,
        uint256 _from,
        uint256 _at
    ) internal pure returns (uint256) {
        uint256 rewardPerClaimTime = (_dailyReturn / 1 days) * _claimTime;

        uint256 secondsSinceCreation = _at - _from;
        uint256 claimTimeSinceCreation = secondsSinceCreation / _claimTime;

        return (claimTimeSinceCreation * rewardPerClaimTime);
    }

    /**
     * @dev Compute product info (value) at a given date.
     * @param _tokenId The product token ID.
     * @param _at The return end date.
     * @param _elexirFactor The Elexir Factor.
     */
    function getProductInfoAt(
        uint256 _tokenId,
        uint256 _at,
        uint64 _elexirFactor
    ) external view returns (ProductComputedAtInfo memory) {
        Product memory product = _productById[_tokenId];
        uint256 dailyReturn = _computeProductDailyReturn(
            product.baseDailyReturn,
            _elexirFactor,
            product.level,
            product.rewardBooster
        );

        uint256 claimTime = 1 minutes;
        uint256 valueAt = _computeProductValueAt(
            dailyReturn,
            claimTime,
            product.lastClaimedAt,
            _at
        );

        ProductComputedAtInfo memory productInfoAt = ProductComputedAtInfo(
            product,
            dailyReturn,
            valueAt,
            _at
        );

        return productInfoAt;
    }

    /**
     * @dev Compute product info (value) of the given IDs.
     * @param _tokensId The product token ID.
     * @param _elexirFactor The Elexir Factor.
     */
    function getProductsInfo(uint256[] memory _tokensId, uint64 _elexirFactor)
        external
        view
        returns (ProductComputedInfo[] memory)
    {
        ProductComputedInfo[] memory productsInfo = new ProductComputedInfo[](
            _tokensId.length
        );

        for (uint256 i = 0; i < _tokensId.length; i++) {
            uint256 productId = _tokensId[i];
            Product memory product = _productById[productId];

            uint256 dailyReturn = _computeProductDailyReturn(
                product.baseDailyReturn,
                _elexirFactor,
                product.level,
                product.rewardBooster
            );

            uint256 claimTime = 1 minutes;
            uint256 valueNow = _computeProductValueAt(
                dailyReturn,
                claimTime,
                product.lastClaimedAt,
                block.timestamp
            );
            uint256 value1Month = _computeProductValueAt(
                dailyReturn,
                claimTime,
                product.lastClaimedAt,
                block.timestamp + 30 days
            );
            uint256 value1Year = _computeProductValueAt(
                dailyReturn,
                claimTime,
                product.lastClaimedAt,
                block.timestamp + 365 days
            );

            productsInfo[i] = ProductComputedInfo(
                product,
                dailyReturn,
                valueNow,
                value1Month,
                value1Year,
                block.timestamp
            );
        }
        return productsInfo;
    }

    /**
     * @dev List account product IDs.
     * @param _account The product owner account.
     */
    function getProductsIdByAccount(address _account)
        external
        view
        returns (uint256[] memory)
    {
        uint256 numberOfProducts = balanceOf(_account);
        uint256[] memory productsId = new uint256[](numberOfProducts);
        for (uint256 i = 0; i < numberOfProducts; i++) {
            uint256 productId = tokenOfOwnerByIndex(_account, i);
            require(
                _exists(productId),
                "YieldProductERC721:TOKEN_DOES_NOT_EXISTS"
            );
            productsId[i] = productId;
        }
        return productsId;
    }
}
