pragma solidity 0.4.24;

import "./zep/SafeMath.sol";
import "./MPToken.sol";

contract marketplace {
    using SafeMath for uint;

    // 売り手による商品の追加
    event NewItem(uint itemIndex);

    // 購入プロセスのフェーズ変化
    event PurchaseChange(Stages stage);

    // 買い手による商品の購入
    event BuyItem(uint itemIndex, uint units, address relayerAddr, uint purchaseIndex);

    // 買い手と売り手による互いの評価
    event PurchaseReview(address reviewer, address reviewee, Roles revieweeRole, uint8 rating, bytes32 ipfsHash);

    // 売り手による商品のキャンセル
    event CancelItem(uint itemIndex);


    // 購入フェーズ
    enum Stages {       
        BUYER_PENDING, // 買い手が商品を受け取った確認待ち
        SELLER_PENDING, // 売り手の買い手に対する評価待ち
        IN_DISPUTE, // 買い手あるいは売り手に対する不正チャレンジ        
        COMPLETE // プロセス完了
    }

    enum Roles {
        SELLER,
        BUYER
    }


    // 商品
    struct Item {
        address seller; // この商品の売り手
        bytes32 ipfsHash; // メタデータ
        uint price; // 単位個数あたりの価格
        uint unitsAvailable; // 商品の個数
        uint created; // この商品が販売開始したときのタイムスタンプ
        mapping(address => uint) relayerFee; // この商品が売れたときにリレイヤーに支払われる手数料            
    }

    // ある商品に対する購入情報
    struct Purchase {
        address buyer;
        uint units;
        uint created;
        Stages stage;
    }


    // 商品の配列
    Item[] public items;

    // それぞれのitemIndexに対するそれぞれの購入情報
    mapping(uint => Purchase[]) public purchases; 

    // コントラクトが保持しているアドレスごとのETH
    mapping(address => uint) public ethBalances;

    // デポジットしているMPToken
    mapping(address => uint) public escrowBalances;

    // コントラクトのオーナー
    address public owner;

    MPToken public token;

    // 適切なステージかチェック
    modifier atStage(Stages _stage, uint _itemIndex, uint _purchaseIndex) {
        require(purchases[_itemIndex][_purchaseIndex].stage == _stage);
        _;
    }

    // 特定の商品の特定の購入情報の買い手かチェック
    modifier isBuyer(uint _itemIndex, uint _purchaseIndex) {
        require(msg.sender == purchases[_itemIndex][_purchaseIndex].buyer);
        _;
    }

    // 特定の商品の売り手かチェック
    modifier isSeller(uint _itemIndex) {
        require(msg.sender == items[_itemIndex].seller);
        _;
    }


    constructor(MPToken _token)
        public
    {
        require(_token != address(0));
        owner = msg.sender;
        token = _token;
    }

    /**
     * @dev 売り手がitemをマーケットに登録する
     * @param _ipfsHash メタデータ
     * @param _price アイテムの価格
     * @param _unitsAvailable 販売する個数         
     * @return 商品数
     */
    function registerItem(
        bytes32 _ipfsHash, 
        uint _price, 
        uint _unitsAvailable        
    )
        public
        returns (uint)
    {
        require(_price != 0 && _unitsAvailable != 0); // 価格と個数がゼロではないか
        Item memory item = Item({
            seller: msg.sender,
            ipfsHash: _ipfsHash,
            price: _price,
            unitsAvailable: _unitsAvailable,
            created: now
        });
        items.push(item);
        
        emit NewItem(items.length.sub(1));

        uint amount = _price; // デポジットすべきMPTokenはアイテムの価格と同じ
        escrowBalances[msg.sender] = escrowBalances[msg.sender].add(amount); 
        require(token.transferFrom(msg.sender, this, amount));  

        return items.length;
    }

    // リレイヤーが自身のdAppsに載せるアイテムをピックアップ
    function pickUp(uint _itemIndex, uint _fee, address _relayerAddr)
        public
    {
        require(_relayerAddr != address(0));
        require(items[_itemIndex].seller != address(0)); // まだ登録されていないアイテムをピックアップしていないか
        Item storage item = items[_itemIndex];
        item.relayerFee[_relayerAddr] = _fee;        
    }

    // 買い手が商品を買う。特定のリレイヤーに対して手数料を支払う。
    function buy(uint _itemIndex, uint _units, address _relayerAddr)
        public    
        payable
        returns (uint)
    {
        require(_relayerAddr != address(0));
        require(_units <= item.unitsAvailable);        
        require(msg.sender != _relayerAddr); // 買い手とリレイヤーのアドレスが同じではないか

        Item storage item = items[_itemIndex];
        require(msg.sender != item.seller); // 買い手と売り手のアドレスが同じではないか
        require(item.relayerFee[_relayerAddr] != 0); // この商品を指定したリレイヤーがピックアップしているかチェック
        
        uint valueToSeller = _units.mul(item.price);
        uint feeToRelayer = item.relayerFee[_relayerAddr];    
        
        require(msg.sender.balance >= valueToSeller.add(feeToRelayer)); // 購入金額と手数料を合計した以上のETHを持っているか
        
        item.unitsAvailable = item.unitsAvailable.sub(_units); // 在庫から買う個数分引く

        Purchase memory purchase = Purchase({
            buyer: msg.sender,
            units: _units,
            created: now,
            stage: Stages.BUYER_PENDING
        });                
        purchases[_itemIndex].push(purchase); // 購買情報の追加
        
        emit BuyItem(_itemIndex, _units, _relayerAddr, purchases[_itemIndex].length.sub(1));
        emit PurchaseChange(purchase.stage);

        ethBalances[item.seller] = ethBalances[item.seller].add(valueToSeller);
        ethBalances[_relayerAddr] = ethBalances[_relayerAddr].add(msg.value.sub(valueToSeller));                

        return purchases[_itemIndex].length;
    }

    // 買い手による売り手への評価
    // TODO: sync identity for rating
    // TODO: set limit days
    // TODO: incentivise review
    function ReviewByBuyer(uint8 _rating, uint _itemIndex, uint _purchaseIndex, bytes32 _ipfsHash)
        public
        isBuyer(_itemIndex, _purchaseIndex)
        atStage(Stages.BUYER_PENDING, _itemIndex, _purchaseIndex)
    {
        require(_rating >= 1);
        require(_rating <= 5);

        purchases[_itemIndex][_purchaseIndex].stage = Stages.SELLER_PENDING;

        token.transferFrom(this, items[_itemIndex].seller, items[_itemIndex].price); // 買い手が評価すると、売り手がデポジットしていたMPTが返金
        emit PurchaseChange(Stages.SELLER_PENDING);
        emit PurchaseReview(msg.sender, items[_itemIndex].seller, Roles.SELLER, _rating, _ipfsHash);
    }

    //売り手による買い手への評価
    function ReviewBySeller(uint8 _rating, uint _itemIndex, uint _purchaseIndex, bytes32 _ipfsHash)
        public
        isSeller(_itemIndex)
        atStage(Stages.SELLER_PENDING, _itemIndex, _purchaseIndex)
    {
        require(_rating >= 1);
        require(_rating <= 5);

        purchases[_itemIndex][_purchaseIndex].stage = Stages.COMPLETE;

        emit PurchaseChange(Stages.COMPLETE);
        emit PurchaseReview(purchases[_itemIndex][_purchaseIndex].buyer, msg.sender, Roles.BUYER, _rating, _ipfsHash);
    }

    // TODO
    function openDispute(uint _itemIndex, uint _purchaseIndex)
        public
        isBuyer(_itemIndex, _purchaseIndex)
    {
        
    }

    function cancel(uint _itemIndex)
        public
        isSeller(_itemIndex)
    {
        items[_itemIndex].unitsAvailable = 0;
        emit CancelItem(_itemIndex);
    }

    // リレイヤーがピックアップしたい商品を探すときに利用
    // TODO: make scale : DLL & Pagination
    // https://programtheblockchain.com/posts/2018/04/20/storage-patterns-pagination/
    function getAllItems()
        public       
        view 
        returns (address[], bytes32[], uint[], uint[], uint[])
    {
        address[] memory sellers = new address[](items.length);        
        bytes32[] memory ipfsHashes = new bytes32[](items.length);
        uint[] memory prices = new uint[](items.length);
        uint[] memory unitsAvailables = new uint[](items.length);
        uint[] memory createds = new uint[](items.length);        

        for (uint i = 0; i < items.length; i++) {            
            Item storage item = items[i];
            sellers[i] = item.seller;
            ipfsHashes[i] = item.ipfsHash;
            prices[i] = item.price;
            unitsAvailables[i] = item.unitsAvailable;
            createds[i] = item.created;
        }

        return (sellers, ipfsHashes, prices, unitsAvailables, createds);
    }        

    function withdraw()
        public
    {
        require(ethBalances[msg.sender] != 0);
        uint amountToWithdraw = ethBalances[msg.sender]; // Reentrancyを避ける
        ethBalances[msg.sender] = 0;
        msg.sender.transfer(amountToWithdraw);
    } 

    function getBalance()
        public
        view
        returns (uint)
    {
        return ethBalances[msg.sender];
    }    

    function getItemsLength()
        public
        view
        returns (uint)
    {
        return items.length;
    }


}