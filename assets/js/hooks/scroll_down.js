export default {
  mounted() {
    this.handleEvent("scroll", () => {
      this.el.scrollTop = this.el.scrollHeight;
    });
    // Auto scroll on mount
    this.el.scrollTop = this.el.scrollHeight;
    
    // Auto scroll on mutation (new content)
    this.observer = new MutationObserver(() => {
      this.el.scrollTop = this.el.scrollHeight;
    });
    this.observer.observe(this.el, { childList: true, subtree: true, characterData: true });
  },
  destroyed() {
    if (this.observer) this.observer.disconnect();
  }
}
