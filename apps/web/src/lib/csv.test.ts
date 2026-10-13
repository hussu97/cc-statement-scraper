import { describe, expect, it } from "vitest";
import { activityCsv, activityCsvFilename, csvCell, toCsv, type ExportRow } from "./csv";

describe("csvCell", () => {
  it("leaves plain text alone and empties null", () => {
    expect(csvCell("Carrefour")).toBe("Carrefour");
    expect(csvCell(null)).toBe("");
    expect(csvCell(undefined)).toBe("");
    expect(csvCell("")).toBe("");
  });

  it("neutralises cells a spreadsheet would run as a formula", () => {
    expect(csvCell("=1+1")).toBe("'=1+1");
    expect(csvCell("+971 50 000 0000")).toBe("'+971 50 000 0000");
    expect(csvCell("-cmd")).toBe("'-cmd");
    expect(csvCell("@SUM(A1)")).toBe("'@SUM(A1)");
    expect(csvCell("\tTAB")).toBe("'\tTAB");
  });

  it("keeps money decimal strings as numbers, negative included", () => {
    expect(csvCell("-40.00")).toBe("-40.00");
    expect(csvCell("1234.50")).toBe("1234.50");
    expect(csvCell("0")).toBe("0");
    expect(csvCell("-")).toBe("'-");
    expect(csvCell("-1e5")).toBe("'-1e5");
  });

  it("quotes commas, quotes, line breaks and edge whitespace", () => {
    expect(csvCell("BAYLEAF RESTAURANT,DUBAI")).toBe('"BAYLEAF RESTAURANT,DUBAI"');
    expect(csvCell('say "hi"')).toBe('"say ""hi"""');
    expect(csvCell("two\nlines")).toBe('"two\nlines"');
    expect(csvCell(" padded ")).toBe('" padded "');
  });

  it("neutralises and then quotes", () => {
    expect(csvCell('=HYPERLINK("x") SHOP')).toBe('"\'=HYPERLINK(""x"") SHOP"');
  });
});

describe("toCsv", () => {
  it("joins with commas and CRLF, with a trailing line break", () => {
    expect(toCsv(["a", "b"], [["1", null], ["x,y", "=z"]])).toBe('a,b\r\n1,\r\n"x,y",\'=z\r\n');
  });
});

const row = (over: Partial<ExportRow> = {}): ExportRow => ({
  txn_code: "txn_01k00000000000000000000000",
  txn_date: "2026-08-03",
  txn_time: "00:30",
  description: "T44 REFUND",
  merchant_name: "Shop",
  category_name: "Shopping",
  bank_code: "ADCB",
  card_last4: "1234",
  account_nickname: null,
  direction: "credit",
  amount_original: "40.00",
  currency_original: "AED",
  amount_aed: "40.00",
  net_aed: "-40.00",
  amount_aed_is_estimate: false,
  status: "posted",
  source: "statement",
  exclude_from_spend: true,
  notes: "=cmd|' /C calc'!A0",
  ...over,
});

describe("activityCsv", () => {
  it("writes a header and one line per server row, money as the server sent it", () => {
    const lines = activityCsv([row()]).split("\r\n");
    expect(lines[0]).toBe(
      "Date,Time,Description,Merchant,Category,Card,Account,Direction,Amount,Currency,Amount AED,Net AED,AED estimated,Status,Source,Excluded from spend,Notes,Transaction code",
    );
    expect(lines[1]).toBe(
      "2026-08-03,00:30,T44 REFUND,Shop,Shopping,ADCB •1234,,credit,40.00,AED,40.00,-40.00,no,posted,statement,yes,'=cmd|' /C calc'!A0,txn_01k00000000000000000000000",
    );
    expect(lines).toHaveLength(3);
    expect(lines[2]).toBe("");
  });

  it("leaves unknown values empty", () => {
    const line = activityCsv([row({ amount_aed: null, net_aed: null, card_last4: null, bank_code: null, txn_time: null, notes: null })]).split("\r\n")[1]!;
    expect(line).toBe("2026-08-03,,T44 REFUND,Shop,Shopping,,,credit,40.00,AED,,,no,posted,statement,yes,,txn_01k00000000000000000000000");
  });

  it("is only a header for no rows", () => {
    expect(activityCsv([]).split("\r\n")).toHaveLength(2);
  });

  it("names the file by the day", () => {
    expect(activityCsvFilename("2026-10-13")).toBe("bank-ledger-activity-2026-10-13.csv");
  });
});
