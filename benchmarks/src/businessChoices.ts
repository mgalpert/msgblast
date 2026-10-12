import { keys, object, requireValue, text } from "./http";

// Display-only labels and selection; never publish Messages IDs or action targets.
export interface BusinessChoices {
  kind: "quickReply" | "listPicker" | "unsupported";
  title: string;
  options: { title: string; selected: boolean; subtitle?: string; section?: string }[];
}
export function validateBusinessChoices(value: unknown) {
  const card = object(value);
  keys(card, ["kind", "title", "options"]);
  requireValue(["quickReply", "listPicker", "unsupported"].includes(String(card.kind)));
  text(card.title, 4096);
  requireValue(Array.isArray(card.options) && card.options.length <= 500);
  for (const value of card.options) {
    const option = object(value);
    keys(option, ["title", "selected", "subtitle", "section"]);
    text(option.title, 4096);
    requireValue(typeof option.selected === "boolean");
    if (option.subtitle !== undefined) text(option.subtitle, 4096);
    if (option.section !== undefined) text(option.section, 4096);
  }
}
