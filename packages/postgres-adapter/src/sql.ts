export const shifted = (sql: string, offset: number) =>
  sql.replace(/\$(\d+)/g, (_, index: string) => `$${Number(index) + offset}`);

export const quote = (identifier: string): string => {
  const parts = identifier.split(".");
  if (!parts.every((part) => /^[A-Za-z_][A-Za-z0-9_$]*$/.test(part))) {
    throw new Error(`Invalid SQL identifier: ${identifier}`);
  }
  return parts.map((part) => `"${part}"`).join(".");
};

export const selection = (select?: string[]): string => {
  return select?.length ? select.map(quote).join(", ") : "*";
};