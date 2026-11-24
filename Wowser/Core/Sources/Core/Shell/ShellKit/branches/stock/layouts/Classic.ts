import { useSidebarWidth } from "../kit/Sidebar.ts";

export default function Classic() {
  const [sidebarWidth] = useSidebarWidth();
  return { sidebarWidth };
}
