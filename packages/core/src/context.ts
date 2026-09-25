export type BasicTypes = string | number | boolean;

export type Context = {
  [Key in string]: BasicTypes | Context | Context[];
};