const TSDOC_BLOCK_PATTERN = /^\/\*\*[\s\S]*\*\/$/;

export function normalizeTSDocDescription(value: string): string {
  const raw = value.trim();
  if (!TSDOC_BLOCK_PATTERN.test(raw)) {
    throw new Error("tool.description must be a TSDoc block comment string");
  }

  const inner = raw
    .replace(/^\/\*\*/, "")
    .replace(/\*\/$/, "")
    .split("\n")
    .map((line) => {
      // Allow intentionally blank lines between TSDoc body lines.
      if (line.trim() === "") {
        return "";
      }

      const markerMatch = line.match(/^\s*\*(?:\s|$)/);
      if (!markerMatch) {
        throw new Error("tool.description must use standard TSDoc line prefixes");
      }

      let content = line.slice(markerMatch[0].length);
      // Remove at most one post-marker space to keep intentional indentation in content.
      if (content.startsWith(" ")) {
        content = content.slice(1);
      }
      return content.trimEnd();
    });

  const normalized = inner.join("\n").trim();
  if (!normalized) {
    throw new Error("tool.description TSDoc block cannot be empty");
  }

  return normalized;
}
