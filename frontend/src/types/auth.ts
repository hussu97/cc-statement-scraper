export type LoginResponse = {
  user: {
    email: string;
    display_name: string;
    default_profile_key: string;
    role: string;
  };
};
