import { useNow } from "wowser";

export default function Clock() {
  const now = new Date(useNow(1000));
  return {
    time: now.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }),
    date: now.toLocaleDateString([], { weekday: "long", month: "short", day: "numeric" }),
  };
}
