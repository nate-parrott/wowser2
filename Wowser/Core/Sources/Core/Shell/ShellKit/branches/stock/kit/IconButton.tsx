import { Pressable, Icon, type BoxStyle, type PressEvent } from "wowser";
import { toolbarButton } from "./theme";

/** A square icon button in the toolbar style. */
export function IconButton(props: {
  icon: string;
  onPress?: (e: PressEvent) => void;
  disabled?: boolean;
  tooltip?: string;
  size?: number;
  style?: BoxStyle;
  testID?: string;
}) {
  return (
    <Pressable
      style={{ ...toolbarButton, ...props.style }}
      onPress={props.onPress}
      disabled={props.disabled}
      tooltip={props.tooltip}
      label={props.tooltip}
      testID={props.testID}
    >
      <Icon name={props.icon} size={props.size ?? 13} weight="medium" />
    </Pressable>
  );
}
