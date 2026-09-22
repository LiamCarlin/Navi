/** `calc(var(--u) * n)`: sizes drawn in screen units so UI scales with the MacBook. Set `--u: 1px` for real pixels. */
export const u = (n: number) => `calc(var(--u) * ${n})`;
