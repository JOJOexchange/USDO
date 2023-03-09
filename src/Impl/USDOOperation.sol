/*
    Copyright 2022 JOJO Exchange
    SPDX-License-Identifier: BUSL-1.1*/

pragma solidity 0.8.9;

import "./USDOBankStorage.sol";
import "../utils/USDOError.sol";
import "../lib/JOJOConstant.sol";
import {DecimalMath} from "../lib/DecimalMath.sol";

/// @notice Owner-only functions
abstract contract USDOOperation is USDOBankStorage {
    using DecimalMath for uint256;

    // ========== event ==========
    event UpdateInsurance(address oldInsurance, address newInsurance);
    event UpdateJOJODealer(address oldJOJODealer, address newJOJODealer);
    event SetOperator(
        address indexed client,
        address indexed operator,
        bool isOperator
    );
    event UpdateOracle(address collateral, address newOracle);
    event UpdateBorrowFeeRate(
        uint256 newBorrowFeeRate,
        uint256 newT0Rate,
        uint32 lastUpdateTimestamp
    );
    event UpdateMaxReservesAmount(
        uint256 maxReservesAmount,
        uint256 newMaxReservesAmount
    );
    event RemoveReserve(address indexed collateral);
    event ReRegisterReserve(address indexed collateral);
    event UpdateReserveRiskParam(
        address indexed collateral,
        uint256 liquidationMortgageRate,
        uint256 liquidationPriceOff,
        uint256 insuranceFeeRate
    );
    event UpdatePrimaryAsset(
        address indexed usedPrimary,
        address indexed newPrimary
    );
    event UpdateReserveParam(
        address indexed collateral,
        uint256 initialMortgageRate,
        uint256 maxTotalDepositAmount,
        uint256 maxDepositAmountPerAccount,
        uint256 maxBorrowValue
    );
    event UpdateMaxBorrowAmount(
        uint256 maxPerAccountBorrowAmount,
        uint256 maxTotalBorrowAmount
    );

    /// @notice initial the param of each reserve
    function initReserve(
        address _collateral,
        uint256 _initialMortgageRate,
        uint256 _maxTotalDepositAmount,
        uint256 _maxDepositAmountPerAccount,
        uint256 _maxBorrowValue,
        uint256 _liquidationMortgageRate,
        uint256 _liquidationPriceOff,
        uint256 _insuranceFeeRate,
        address _oracle
    ) external onlyOwner {
        require(
            JOJOConstant.ONE - _liquidationMortgageRate >
                _liquidationPriceOff +
                    (JOJOConstant.ONE - _liquidationPriceOff).decimalMul(
                        _insuranceFeeRate
                    ),
            USDOErrors.RESERVE_PARAM_ERROR
        );
        reserveInfo[_collateral].initialMortgageRate = _initialMortgageRate;
        reserveInfo[_collateral].maxTotalDepositAmount = _maxTotalDepositAmount;
        reserveInfo[_collateral]
            .maxDepositAmountPerAccount = _maxDepositAmountPerAccount;
        reserveInfo[_collateral].maxBorrowValue = _maxBorrowValue;
        reserveInfo[_collateral]
            .liquidationMortgageRate = _liquidationMortgageRate;
        reserveInfo[_collateral].liquidationPriceOff = _liquidationPriceOff;
        reserveInfo[_collateral].insuranceFeeRate = _insuranceFeeRate;
        reserveInfo[_collateral].isDepositAllowed = true;
        reserveInfo[_collateral].isBorrowAllowed = true;
        reserveInfo[_collateral].oracle = _oracle;
        _addReserve(_collateral);
    }

    function _addReserve(address collateral) private {
        require(
            reservesNum <= maxReservesNum,
            USDOErrors.NO_MORE_RESERVE_ALLOWED
        );
        reservesList.push(collateral);
        reservesNum += 1;
    }

    /// @notice update the max borrow amount of total and per account
    function updateMaxBorrowAmount(
        uint256 _maxBorrowAmountPerAccount,
        uint256 _maxTotalBorrowAmount
    ) external onlyOwner {
        maxTotalBorrowAmount = _maxTotalBorrowAmount;
        maxPerAccountBorrowAmount = _maxBorrowAmountPerAccount;
        emit UpdateMaxBorrowAmount(
            maxPerAccountBorrowAmount,
            maxTotalBorrowAmount
        );
    }

    /// @notice update the insurance account
    function updateInsurance(address newInsurance) external onlyOwner {
        emit UpdateInsurance(insurance, newInsurance);
        insurance = newInsurance;
    }

    /// @notice update JOJODealer address
    function updateJOJODealer(address newJOJODealer) external onlyOwner {
        emit UpdateJOJODealer(JOJODealer, newJOJODealer);
        JOJODealer = newJOJODealer;
    }

    /// @notice update collateral oracle
    function updateOracle(
        address collateral,
        address newOracle
    ) external onlyOwner {
        DataTypes.ReserveInfo storage reserve = reserveInfo[collateral];
        reserve.oracle = newOracle;
        emit UpdateOracle(collateral, newOracle);
    }

    function updateMaxReservesAmount(
        uint256 newMaxReservesAmount
    ) external onlyOwner {
        emit UpdateMaxReservesAmount(maxReservesNum, newMaxReservesAmount);
        maxReservesNum = newMaxReservesAmount;
    }

    function updatePrimaryAsset(address newPrimary) external onlyOwner {
        emit UpdatePrimaryAsset(primaryAsset, newPrimary);
        primaryAsset = newPrimary;
    }

    /// @notice update the borrow fee rate
    // t0Rate and lastUpdateTimestamp will be updated according to the borrow fee rate
    function updateBorrowFeeRate(uint256 _borrowFeeRate) external onlyOwner {
        t0Rate = getTRate();
        lastUpdateTimestamp = uint32(block.timestamp);
        borrowFeeRate = _borrowFeeRate;
        emit UpdateBorrowFeeRate(_borrowFeeRate, t0Rate, lastUpdateTimestamp);
    }

    /// @notice update the reserve risk params
    function updateRiskParam(
        address collateral,
        uint256 _liquidationMortgageRate,
        uint256 _liquidationPriceOff,
        uint256 _insuranceFeeRate
    ) external onlyOwner {
        require(
            JOJOConstant.ONE - _liquidationMortgageRate >
                _liquidationPriceOff +
                    ((JOJOConstant.ONE - _liquidationPriceOff) *
                        _insuranceFeeRate) /
                    JOJOConstant.ONE,
            USDOErrors.RESERVE_PARAM_ERROR
        );
        reserveInfo[collateral]
            .liquidationMortgageRate = _liquidationMortgageRate;
        reserveInfo[collateral].liquidationPriceOff = _liquidationPriceOff;
        reserveInfo[collateral].insuranceFeeRate = _insuranceFeeRate;
        emit UpdateReserveRiskParam(
            collateral,
            _liquidationMortgageRate,
            _liquidationPriceOff,
            _insuranceFeeRate
        );
    }

    /// @notice update the reserve basic params
    function updateReserveParam(
        address collateral,
        uint256 _initialMortgageRate,
        uint256 _maxTotalDepositAmount,
        uint256 _maxDepositAmountPerAccount,
        uint256 _maxBorrowValue
    ) external onlyOwner {
        reserveInfo[collateral].initialMortgageRate = _initialMortgageRate;
        reserveInfo[collateral].maxTotalDepositAmount = _maxTotalDepositAmount;
        reserveInfo[collateral]
            .maxDepositAmountPerAccount = _maxDepositAmountPerAccount;
        reserveInfo[collateral].maxBorrowValue = _maxBorrowValue;
        emit UpdateReserveParam(
            collateral,
            _initialMortgageRate,
            _maxTotalDepositAmount,
            _maxDepositAmountPerAccount,
            _maxBorrowValue
        );
    }

    /// @notice remove the reserve, need to modify the market status
    /// which means this reserve is delist
    function delistReserve(address collateral) external onlyOwner {
        DataTypes.ReserveInfo storage reserve = reserveInfo[collateral];
        reserve.isBorrowAllowed = false;
        reserve.isDepositAllowed = false;
        reserve.isFinalLiquidation = true;
        emit RemoveReserve(collateral);
    }

    /// @notice relist the delist reserve
    function relistReserve(address collateral) external onlyOwner {
        DataTypes.ReserveInfo storage reserve = reserveInfo[collateral];
        reserve.isBorrowAllowed = true;
        reserve.isDepositAllowed = true;
        reserve.isFinalLiquidation = false;
        emit ReRegisterReserve(collateral);
    }

    /// @notice Update the sub account
    function setOperator(address operator, bool isOperator) external {
        operatorRegistry[msg.sender][operator] = isOperator;
        emit SetOperator(msg.sender, operator, isOperator);
    }
}
