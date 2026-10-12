function selectAgent(id) {
  document
    .querySelectorAll(".agent")
    .forEach((node) =>
      node.classList.toggle("selected", node.dataset.agent === id),
    );
  document
    .querySelectorAll("button[data-agent]")
    .forEach((button) =>
      button.setAttribute("aria-pressed", String(button.dataset.agent === id)),
    );
}
document
  .querySelectorAll("button[data-agent]")
  .forEach((button) =>
    button.addEventListener("click", () => selectAgent(button.dataset.agent)),
  );
// bfcache may retain a page even with no-store. Recheck authoritative access before showing restored content.
window.addEventListener("pageshow", async (event) => {
  if (!event.persisted) return;
  document.querySelector("main").hidden = true;
  try {
    const response = await fetch(location.pathname + "/data", {
      cache: "no-store",
    });
    if (!response.ok) {
      location.reload();
      return;
    }
    location.reload();
  } catch {
    location.reload();
  }
});
