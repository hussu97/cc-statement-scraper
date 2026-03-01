import { Component, type ErrorInfo, type ReactNode } from 'react';

interface Props {
  children: ReactNode;
}

interface State {
  hasError: boolean;
  error: Error | null;
}

export class ErrorBoundary extends Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = { hasError: false, error: null };
  }

  static getDerivedStateFromError(error: Error): State {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('Unhandled render error:', error, info.componentStack);
  }

  render() {
    if (this.state.hasError) {
      return (
        <div className="login-shell">
          <section className="login-card">
            <h2>Something went wrong</h2>
            <p className="muted" style={{ marginBottom: '1rem' }}>
              {this.state.error?.message ?? 'An unexpected error occurred.'}
            </p>
            <button
              className="primary"
              onClick={() => {
                this.setState({ hasError: false, error: null });
                window.location.reload();
              }}
            >
              Reload page
            </button>
          </section>
        </div>
      );
    }
    return this.props.children;
  }
}
