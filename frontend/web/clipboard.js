export const copyToClipboard = async (
  text,
  clipboard = globalThis.navigator?.clipboard,
  documentRef = globalThis.document,
) => {
  if (clipboard?.writeText) {
    await clipboard.writeText(text);
    return true;
  }
  if (!documentRef?.body || !documentRef.execCommand) return false;

  const field = documentRef.createElement("textarea");
  field.value = text;
  field.setAttribute("readonly", "");
  field.style.position = "fixed";
  field.style.opacity = "0";
  documentRef.body.appendChild(field);
  field.select();
  const copied = documentRef.execCommand("copy");
  field.remove();
  return copied;
};
