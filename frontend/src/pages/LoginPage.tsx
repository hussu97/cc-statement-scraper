import { FormEvent, useEffect, useState } from 'react';
import { Navigate, useLocation, useNavigate } from 'react-router-dom';

import { api } from '../api';
import { setAuthUser, useAuthUser } from '../authStore';
import { DEFAULT_ROUTE } from '../navigation';
import { setActiveProfileKey } from '../profileStore';

type LoginResponse = {
  user: {
    email: string;
    display_name: string;
    default_profile_key: string;
    role: string;
  };
};

const DEFAULT_LOGIN_EMAIL = 'h_abbasi97@hotmail.com';

export function LoginPage() {
  const authUser = useAuthUser();
  const navigate = useNavigate();
  const location = useLocation();
  const [email, setEmail] = useState(DEFAULT_LOGIN_EMAIL);
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!authUser) {
      return;
    }
    setActiveProfileKey(authUser.default_profile_key);
  }, [authUser]);

  if (authUser) {
    return <Navigate to={DEFAULT_ROUTE} replace />;
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    try {
      setLoading(true);
      setError(null);
      const payload = await api.post<LoginResponse>('/auth/login', {
        email: email.trim(),
        password,
      });
      setAuthUser(payload.user);
      setActiveProfileKey(payload.user.default_profile_key);

      const redirectPath =
        typeof (location.state as { from?: unknown } | null)?.from === 'string'
          ? (location.state as { from: string }).from
          : DEFAULT_ROUTE;
      navigate(redirectPath, { replace: true });
    } catch (loginError) {
      setError((loginError as Error).message);
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="login-shell">
      <section className="login-card" aria-label="Admin login">
        <h1>CC Statements</h1>
        <p className="muted">Sign in to the admin panel</p>

        <form className="login-form" onSubmit={handleSubmit}>
          <label>
            <span>Email</span>
            <input
              type="email"
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              autoComplete="username"
              required
            />
          </label>

          <label>
            <span>Password</span>
            <input
              type="password"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              autoComplete="current-password"
              required
            />
          </label>

          <button className="primary" type="submit" disabled={loading}>
            {loading ? 'Signing in...' : 'Sign in'}
          </button>
        </form>

        {error ? <p className="error">{error}</p> : null}
      </section>
    </div>
  );
}
