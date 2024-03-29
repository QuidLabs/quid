/* Autogenerated file. Do not edit manually. */

/* tslint:disable */
/* eslint-disable */

/*
  Fuels version: 0.43.1
  Forc version: 0.35.5
  Fuel-Core version: 0.17.3
*/

import type {
  BigNumberish,
  BN,
  BytesLike,
  Contract,
  DecodedValue,
  FunctionFragment,
  Interface,
  InvokeFunction,
} from 'fuels';

import type { Enum } from "./common";

export enum AssetErrorInput { BelowMinimum = 'BelowMinimum' };
export enum AssetErrorOutput { BelowMinimum = 'BelowMinimum' };
export enum ErrorCRInput { BelowMinimum = 'BelowMinimum' };
export enum ErrorCROutput { BelowMinimum = 'BelowMinimum' };
export enum LiquidationErrorInput { UnableToLiquidate = 'UnableToLiquidate' };
export enum LiquidationErrorOutput { UnableToLiquidate = 'UnableToLiquidate' };
export enum PriceErrorInput { NotInitialized = 'NotInitialized' };
export enum PriceErrorOutput { NotInitialized = 'NotInitialized' };
export enum UpdateErrorInput { TooEarly = 'TooEarly', Deadlock = 'Deadlock' };
export enum UpdateErrorOutput { TooEarly = 'TooEarly', Deadlock = 'Deadlock' };

export type AddressInput = { value: string };
export type AddressOutput = AddressInput;
export type PodInput = { credit: BigNumberish, debit: BigNumberish };
export type PodOutput = { credit: BN, debit: BN };
export type PoolInput = { long: PodInput, short: PodInput };
export type PoolOutput = { long: PodOutput, short: PodOutput };

interface QDAbiInterface extends Interface {
  functions: {
    borrow: FunctionFragment;
    clap: FunctionFragment;
    deposit: FunctionFragment;
    fold: FunctionFragment;
    get_deep: FunctionFragment;
    get_live: FunctionFragment;
    get_pledge_brood: FunctionFragment;
    get_pledge_live: FunctionFragment;
    set_price: FunctionFragment;
    update: FunctionFragment;
    update_longs: FunctionFragment;
    update_shorts: FunctionFragment;
    withdraw: FunctionFragment;
  };

  encodeFunctionData(functionFragment: 'borrow', values: [BigNumberish, boolean]): Uint8Array;
  encodeFunctionData(functionFragment: 'clap', values: [AddressInput]): Uint8Array;
  encodeFunctionData(functionFragment: 'deposit', values: [boolean, boolean]): Uint8Array;
  encodeFunctionData(functionFragment: 'fold', values: [boolean]): Uint8Array;
  encodeFunctionData(functionFragment: 'get_deep', values: []): Uint8Array;
  encodeFunctionData(functionFragment: 'get_live', values: []): Uint8Array;
  encodeFunctionData(functionFragment: 'get_pledge_brood', values: [AddressInput, boolean]): Uint8Array;
  encodeFunctionData(functionFragment: 'get_pledge_live', values: [AddressInput]): Uint8Array;
  encodeFunctionData(functionFragment: 'set_price', values: [BigNumberish]): Uint8Array;
  encodeFunctionData(functionFragment: 'update', values: []): Uint8Array;
  encodeFunctionData(functionFragment: 'update_longs', values: []): Uint8Array;
  encodeFunctionData(functionFragment: 'update_shorts', values: []): Uint8Array;
  encodeFunctionData(functionFragment: 'withdraw', values: [BigNumberish, boolean, boolean]): Uint8Array;

  decodeFunctionData(functionFragment: 'borrow', data: BytesLike): DecodedValue;
  decodeFunctionData(functionFragment: 'clap', data: BytesLike): DecodedValue;
  decodeFunctionData(functionFragment: 'deposit', data: BytesLike): DecodedValue;
  decodeFunctionData(functionFragment: 'fold', data: BytesLike): DecodedValue;
  decodeFunctionData(functionFragment: 'get_deep', data: BytesLike): DecodedValue;
  decodeFunctionData(functionFragment: 'get_live', data: BytesLike): DecodedValue;
  decodeFunctionData(functionFragment: 'get_pledge_brood', data: BytesLike): DecodedValue;
  decodeFunctionData(functionFragment: 'get_pledge_live', data: BytesLike): DecodedValue;
  decodeFunctionData(functionFragment: 'set_price', data: BytesLike): DecodedValue;
  decodeFunctionData(functionFragment: 'update', data: BytesLike): DecodedValue;
  decodeFunctionData(functionFragment: 'update_longs', data: BytesLike): DecodedValue;
  decodeFunctionData(functionFragment: 'update_shorts', data: BytesLike): DecodedValue;
  decodeFunctionData(functionFragment: 'withdraw', data: BytesLike): DecodedValue;
}

export class QDAbi extends Contract {
  interface: QDAbiInterface;
  functions: {
    borrow: InvokeFunction<[amount: BigNumberish, short: boolean], void>;
    clap: InvokeFunction<[who: AddressInput], void>;
    deposit: InvokeFunction<[live: boolean, long: boolean], void>;
    fold: InvokeFunction<[short: boolean], void>;
    get_deep: InvokeFunction<[], PoolOutput>;
    get_live: InvokeFunction<[], PoolOutput>;
    get_pledge_brood: InvokeFunction<[who: AddressInput, eth: boolean], BN>;
    get_pledge_live: InvokeFunction<[who: AddressInput], PoolOutput>;
    set_price: InvokeFunction<[price: BigNumberish], void>;
    update: InvokeFunction<[], void>;
    update_longs: InvokeFunction<[], void>;
    update_shorts: InvokeFunction<[], void>;
    withdraw: InvokeFunction<[amt: BigNumberish, qd: boolean, sp: boolean], void>;
  };
}
