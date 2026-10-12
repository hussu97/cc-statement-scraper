import { Component, type ErrorInfo, type ReactNode } from "react";
import { reportRenderError } from "@/lib/sentry";

// The app's root error boundary. Not Sentry.ErrorBoundary: that would put the SDK in the
// first-load bundle (WEB-11). The error goes to Sentry through captureReactException once it loads.

interface Props {
  fallback: (props: { resetError: () => void }) => ReactNode;
  children: ReactNode;
}

export class ErrorBoundary extends Component<Props, { failed: boolean }> {
  state = { failed: false };

  static getDerivedStateFromError(): { failed: boolean } {
    return { failed: true };
  }

  componentDidCatch(error: unknown, info: ErrorInfo): void {
    reportRenderError(error, info.componentStack);
  }

  resetError = (): void => this.setState({ failed: false });

  render(): ReactNode {
    return this.state.failed ? this.props.fallback({ resetError: this.resetError }) : this.props.children;
  }
}
