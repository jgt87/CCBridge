// The rules of the file upload box (components/kokonutui/file-upload.tsx): sizes as text, the
// checks a chosen file must pass, and the line of accepted types under the title.

export interface FileError {
  message: string;
  code: string;
}

const FILE_SIZES = ["Bytes", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"] as const;

export const formatBytes = (bytes: number, decimals = 2): string => {
  if (!+bytes) return "0 Bytes";
  const k = 1024;
  const dm = decimals < 0 ? 0 : decimals;
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  const unit = FILE_SIZES[i] || FILE_SIZES[FILE_SIZES.length - 1];
  return `${Number.parseFloat((bytes / k ** i).toFixed(dm))} ${unit}`;
};

export function checkFileSize(file: File, maxFileSize: number): FileError | null {
  if (file.size <= maxFileSize) return null;
  return { message: `File size exceeds ${formatBytes(maxFileSize)}`, code: "FILE_TOO_LARGE" };
}

export function checkFileType(file: File, acceptedFileTypes: string[]): FileError | null {
  if (!acceptedFileTypes?.length) return null;
  const fileType = file.type.toLowerCase();
  if (acceptedFileTypes.some((type) => fileType.match(type.toLowerCase()))) return null;
  return { message: `File type must be ${acceptedFileTypes.join(", ")}`, code: "INVALID_FILE_TYPE" };
}

// The first problem with a file, in order: size, type, then the caller's own check.
export function firstFileError(
  file: File,
  maxFileSize: number,
  acceptedFileTypes: string[],
  validateFile?: (file: File) => FileError | null
): FileError | null {
  return checkFileSize(file, maxFileSize) ?? checkFileType(file, acceptedFileTypes) ?? validateFile?.(file) ?? null;
}

// The line under the title: the caller's hint, else the accepted types ("PNG, JPEG").
export function fileTypesHint(hint: string | undefined, acceptedFileTypes: string[]): string {
  if (hint !== undefined && hint !== null) return hint;
  return acceptedFileTypes?.length
    ? acceptedFileTypes.map((t) => t.split("/")[1]).join(", ").toUpperCase()
    : "SVG, PNG, JPG or GIF";
}
