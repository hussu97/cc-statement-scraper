import { Navigate, Outlet, useLocation } from 'react-router-dom';

import { useAuthUser } from '../authStore';

export function RequireAuth() {
  const location = useLocation();
  const authUser = useAuthUser();

  if (!authUser) {
    return <Navigate to="/login" replace state={{ from: location.pathname }} />;
  }

  return <Outlet />;
}
