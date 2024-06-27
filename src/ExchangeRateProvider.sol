// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;


interface IExchangeRateProvider {
    function exchangeRate() external view returns(uint);
    function lastUpdate() external view returns(uint);
    function setExchangeRate(uint) external returns(bool);
    function setLastUpdate(uint) external returns(bool);
}

contract ExchangeRateProvider is IExchangeRateProvider{
    uint _exchangeRate;
    uint _lastUpdate;
    address public owner;
    address public pendingOwner;
    mapping(address => bool) public updaters;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyUpdater() {
        require(updaters[msg.sender], "Only updater");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyPendingOwner() {
        require(msg.sender == pendingOwner, "Only pending owner");
        _;
    }

    function exchangeRate() external view returns(uint){
        return _exchangeRate;
    }

    function lastUpdate() external view returns(uint){
        return _lastUpdate;
    }

    function setExchangeRate(uint newExchangeRate) external onlyUpdater returns(bool){
        if(_exchangeRate <= newExchangeRate) {
            _exchangeRate = newExchangeRate;
            return true;
        }
        return false;
    }

    function setLastUpdate(uint newUpdateTimestamp) external onlyUpdater returns(bool){
        if(_lastUpdate <= newUpdateTimestamp) {
            _lastUpdate = newUpdateTimestamp;
            return true;
        }
        return false;
    }

    function setUpdater(address updater, bool isUpdater) external onlyOwner {
        updaters[updater] = isUpdater;
    }

    function setPendingOwner(address newPendingOwner) external onlyOwner {
        pendingOwner = newPendingOwner;
    }

    function acceptOwner() external onlyPendingOwner {
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}

