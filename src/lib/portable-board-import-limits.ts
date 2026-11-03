export const MAX_PORTABLE_BOARD_PACKAGE_BYTES = 220_000_000;
export const MAX_PORTABLE_BOARD_IMPORT_BYTES = MAX_PORTABLE_BOARD_PACKAGE_BYTES;
// A decision entry can carry one package reference, a user UUID, and small keys.
// This keeps the largest bounded decision payload below the 100k-record package cap.
export const MAX_PORTABLE_BOARD_IMPORT_DECISION_BYTES = 20_000_000;
export const MAX_PORTABLE_BOARD_PACKAGE_ENTRIES = 25_000;
export const MAX_PORTABLE_BOARD_MANIFEST_BYTES = 8_000_000;
export const MAX_PORTABLE_BOARD_CENTRAL_DIRECTORY_BYTES = 32_000_000;
export const MAX_PORTABLE_BOARD_RECORDS = 100_000;
export const MAX_PORTABLE_BOARD_RECORD_BYTES = 256 * 1024;
export const MAX_PORTABLE_BOARD_ATTACHMENT_BYTES = 24_000;
