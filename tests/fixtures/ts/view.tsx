import * as React from "react";

export interface Props {
  title: string;
}

export type Variant = "primary" | "secondary";

export class Panel extends React.Component<Props> {
  render() {
    return <div>{this.props.title}</div>;
  }
}

export function Button<T>({ title }: Props & { data?: T }) {
  return <button>{title}</button>;
}
