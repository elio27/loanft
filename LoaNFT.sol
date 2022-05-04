// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

interface IEmprunteur {
    function doStuff(
        address _nftContract,
        uint256[] calldata _ids,
        uint256[] calldata _amounts,
        bytes calldata _params
        ) external;
}

contract loanft {

    function unsafeIncrement(uint256 i) internal pure returns(uint256) {
        unchecked {
            return i+1;
        }
    }

    struct Collection {
        uint256 stakedAmount;
        uint256 collectedFees;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Permission invalide.");
        _;
    }

    address public owner; // Adresse du proprietaire du contrat
    mapping(address => mapping(uint256 => address)) public erc721Owners;
    mapping(address => mapping(uint256 => mapping(address => uint256))) public erc1155Owners;
    mapping(address => Collection) public collections;
    uint128 public feePerToken; // Prix en eth de l'emprunt d'un NFT
    uint128 public devShare; // Part, sur 1000, de frais pris par l'equipe du projet

    constructor(uint128 _feePerToken, uint128 _devShare) {
        // Definit les variables de contrat
        owner = msg.sender;
        feePerToken = _feePerToken;
        devShare = _devShare;
    }


    /*
        DEPOSER et RECUPERER des NFTs de type ERC721
    */
    function depositERC721(address _nftContract, uint256[] memory _ids) external {
        require(tx.origin == msg.sender, "Only EOAs can deposit.");
        IERC721 _contract = IERC721(_nftContract);
        uint256 len = _ids.length;
        
        for (uint256 i; i<len; i=unsafeIncrement(i)) {
            uint256 id = _ids[i];
            require(_contract.ownerOf(id)!=address(this), "Token already staked.");
            _contract.transferFrom(msg.sender, address(this), id);
            erc721Owners[_nftContract][id] = msg.sender;
        }

        collections[_nftContract].stakedAmount += len;
    }

    function withdrawERC721(address _nftContract, uint256[] memory _ids) external {
        IERC721 _contract = IERC721(_nftContract);
        uint256 len = _ids.length;
        
        for (uint256 i; i<len; i=unsafeIncrement(i)) {
            uint256 id = _ids[i];
            require(erc721Owners[_nftContract][id] == msg.sender, "You don't own this token.");
            _contract.transferFrom(address(this), msg.sender, id);
            erc721Owners[_nftContract][id] = address(0x0);
        }
        collections[_nftContract].stakedAmount -= len;
    }


    /*
        DEPOSER et RECUPERER des NFTs de type ERC1155
    */
    function depositERC1155(address _nftContract, uint256[] memory _ids, uint[] memory _amounts) external {
        
        require(tx.origin == msg.sender, "Only EOAs can deposit.");
        IERC1155 _contract = IERC1155(_nftContract);
        _contract.safeBatchTransferFrom(msg.sender, address(this), _ids, _amounts, "0x0");

        uint256 len = _ids.length;
        
        for (uint256 i; i<len; i=unsafeIncrement(i)) {
            erc1155Owners[_nftContract][_ids[i]][msg.sender] += _amounts[i];
            collections[_nftContract].stakedAmount += _amounts[i];
        }
    }

    function withdrawERC1155(address _nftContract, uint256[] memory _ids, uint256[] memory _amounts) external {
        IERC1155 _contract = IERC1155(_nftContract);
        _contract.safeBatchTransferFrom(address(this), msg.sender, _ids, _amounts, "0x0");

        uint256 len = _ids.length;
        
        for (uint256 i; i<len; i=unsafeIncrement(i)) {
            erc1155Owners[_nftContract][_ids[i]][msg.sender] -= _amounts[i];
            collections[_nftContract].stakedAmount -= _amounts[i];
        }
    }


    /*
        FLASHLOAN 
    */
    function flashloan(address _nftContract, address _executor, uint256 _type, uint[] calldata _ids, uint[] calldata _amounts, bytes calldata _params) external payable {

        // Retient la quantité d'eth dans le contract avant l'execution du flashloan
        uint256 iniBalance = address(this).balance;
        uint256 cost;

        // Le fonctionnement est similaire mais le code est different en fonction du type de NFT voulu
        if (_type == 721) {
            cost = _flashloan721(_nftContract, _executor, _ids, _params) - 1; // le -1 sert a economiser du gas
        }
        else if (_type == 1155) {
            cost = _flashloan1155(_nftContract, _executor,  _ids, _amounts, _params) - 1;
        }
        else {
            revert("Type de token non supporte.");
        }

        require(msg.value > cost || address(this).balance - iniBalance > cost, "Remboursement incorrect");

        // Calcule les parts et envoie les frais de service
        uint256 devFee = cost * devShare / 1000;
        collections[_nftContract].collectedFees = cost - devFee;
        payable(owner).transfer(devFee);

    }

    function _flashloan721(address _nftContract, address _executor, uint[] calldata _ids, bytes calldata _params) internal returns(uint256){
        
        IERC721 _contract = IERC721(_nftContract);
        uint256 len = _ids.length;

        // Envoie les NFTs voulus au contrat executeur
        for (uint256 i; i<len; i=unsafeIncrement(i)) {
            _contract.transferFrom(address(this), _executor, _ids[i]);
        }

        // Execute le code du flashloan
        IEmprunteur(_executor).doStuff(_nftContract, _ids, _ids, _params);

        // Verifie que les NFTs sont bien revenus au contrat et les reprend si ce n'est pas le cas
        for (uint256 i; i<len; i=unsafeIncrement(i)) {
            if (_contract.ownerOf(_ids[i]) != address(this)) {
                _contract.transferFrom(_executor, address(this), _ids[i]);
            }
        }

        // Renvoie le cout de l'emprunt
        return len*feePerToken;

    }

    function _flashloan1155(address _nftContract, address _executor, uint[] calldata _ids, uint[] calldata _amounts, bytes calldata _params) internal returns(uint256){

        IERC1155 _contract = IERC1155(_nftContract);

        // Envoie les NFTs voulus au contrat executeur
        _contract.safeBatchTransferFrom(address(this), _executor, _ids, _amounts,"0x0");

        // Execute le code du flashloan
        IEmprunteur(_executor).doStuff(_nftContract, _ids, _amounts, _params);

        // Recupere les NFTs empruntés
        _contract.safeBatchTransferFrom(_executor, address(this), _ids, _amounts, "0x0");

        // Calcule le montant des frais d'emprunt
        uint256 len = _amounts.length;
        uint256 sum;
        for (uint256 i; i<len; i=unsafeIncrement(i)) {
            unchecked{
                sum += _amounts[i];
            }
        }

        // Renvoie le cout de l'emprunt
        return sum*feePerToken;
    }

    /*
        Voir ses recompenses theoriques
    */

    function rewardsOfUserForCollection(address _user, address _collection, uint256 _type, uint256[] calldata _ids) external view returns(uint256) {
        return _rewardsOfUserForCollection(_user, _collection, _type, _ids);
    }

    function _rewardsOfUserForCollection(address _user, address _collection, uint256 _type, uint256[] calldata _ids) internal view returns(uint256) {
        if (_type == 721) {
            return rewardsOfUserFor721Collection(_user, _collection);
        }
        else {
            return rewardsOfUserFor1155Collection(_user, _collection, _ids);
        }
    }

    function rewardsOfUserFor721Collection(address _user, address _collection) internal view returns(uint256) {
        Collection memory collection = collections[_collection];
        return IERC721(_collection).balanceOf(_user) * collection.collectedFees / collection.stakedAmount;
    }

    function rewardsOfUserFor1155Collection(address _user, address _collection, uint256[] calldata _ids) internal view returns(uint256) {
        uint256 len = _ids.length;
        uint256 bal;
        Collection memory collection = collections[_collection];
        IERC1155 _contract = IERC1155(_collection);
        for (uint256 i; i<len; i=unsafeIncrement(i)) {
            unchecked {
                bal += _contract.balanceOf(_user, _ids[i]);
            }
        }
        return bal * collection.collectedFees / collection.stakedAmount;
    }


    /*
        Les recompenses sont reversees regulierement sur ordre du proprietaire afin d'eviter les attaques 
    */
    function sendRewards(address _collection, address[] calldata _users) external onlyOwner {
        uint256 len = _users.length;
        for (uint256 i; i<len; i=unsafeIncrement(i)) {
            address user = _users[i];
            payable(user).transfer(rewardsOfUserFor721Collection(user, _collection));
        }
    }

    /*
        Fonctions casse-couilles d'Openzeppelin
    */
    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    )   public pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

}
