import { describe, expect, it } from "vitest";
import { checkFileSize, checkFileType, fileTypesHint, firstFileError, formatBytes } from "./file-upload";

const fileOf = (size: number, type: string) => new File([new Uint8Array(size)], "x", { type });

describe("file upload rules", () => {
  it("writes sizes in the largest unit that fits", () => {
    expect(formatBytes(0)).toBe("0 Bytes");
    expect(formatBytes(512)).toBe("512 Bytes");
    expect(formatBytes(1536)).toBe("1.5 KB");
    expect(formatBytes(500 * 1024 * 1024)).toBe("500 MB");
  });

  it("refuses a file over the size limit and names the limit", () => {
    expect(checkFileSize(fileOf(10, "text/plain"), 10)).toBeNull();
    expect(checkFileSize(fileOf(11, "text/plain"), 10)).toEqual({ message: "File size exceeds 10 Bytes", code: "FILE_TOO_LARGE" });
  });

  it("accepts any type without a list, else only the listed ones, ignoring case", () => {
    expect(checkFileType(fileOf(1, "application/zip"), [])).toBeNull();
    expect(checkFileType(fileOf(1, "image/PNG"), ["image/png"])).toBeNull();
    expect(checkFileType(fileOf(1, "image/jpeg"), ["image/*"])).toBeNull();
    expect(checkFileType(fileOf(1, "text/csv"), ["image/png", "image/gif"])?.message).toBe("File type must be image/png, image/gif");
  });

  it("reports the first problem: size, then type, then the caller's own check", () => {
    const own = () => ({ message: "own", code: "OWN" });
    expect(firstFileError(fileOf(20, "text/csv"), 10, ["image/png"], own)?.code).toBe("FILE_TOO_LARGE");
    expect(firstFileError(fileOf(5, "text/csv"), 10, ["image/png"], own)?.code).toBe("INVALID_FILE_TYPE");
    expect(firstFileError(fileOf(5, "image/png"), 10, ["image/png"], own)?.code).toBe("OWN");
    expect(firstFileError(fileOf(5, "image/png"), 10, ["image/png"], () => null)).toBeNull();
    expect(firstFileError(fileOf(5, "image/png"), 10, [])).toBeNull();
  });

  it("shows the caller's hint, else the accepted types, else the default line", () => {
    expect(fileTypesHint("Any file type.", ["image/png"])).toBe("Any file type.");
    expect(fileTypesHint("", ["image/png"])).toBe("");
    expect(fileTypesHint(undefined, ["image/png", "image/jpeg"])).toBe("PNG, JPEG");
    expect(fileTypesHint(undefined, [])).toBe("SVG, PNG, JPG or GIF");
  });
});
