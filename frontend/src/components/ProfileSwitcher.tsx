import { useEffect, useMemo, useState } from 'react';

import { api } from '../api';
import { setActiveProfileKey, useActiveProfileKey } from '../profileStore';

type ProfileOut = {
  key: string;
  name: string;
  is_default: boolean;
  banks: string[];
};

const DEFAULT_BANK_CODES = ['FAB', 'ADCB', 'ENBD'];

function dedupeSorted(values: string[]): string[] {
  return [...new Set(values.map((token) => token.toUpperCase().trim()).filter(Boolean))].sort();
}

export function ProfileSwitcher() {
  const activeProfileKey = useActiveProfileKey();
  const [profiles, setProfiles] = useState<ProfileOut[]>([]);
  const [editingBanks, setEditingBanks] = useState<string[]>([]);
  const [saving, setSaving] = useState(false);
  const [loading, setLoading] = useState(false);
  const [statusMessage, setStatusMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const activeProfile = profiles.find((profile) => profile.key === activeProfileKey) || null;
  const allBankCodes = useMemo(() => {
    const values = new Set(DEFAULT_BANK_CODES);
    profiles.forEach((profile) => profile.banks.forEach((bank) => values.add(bank)));
    return [...values].sort();
  }, [profiles]);

  async function loadProfiles() {
    try {
      setLoading(true);
      setError(null);
      const rows = await api.get<ProfileOut[]>('/profiles');
      setProfiles(rows);

      const exists = rows.some((profile) => profile.key === activeProfileKey);
      if (!exists && rows.length > 0) {
        const fallback = rows.find((profile) => profile.is_default)?.key || rows[0].key;
        setActiveProfileKey(fallback);
      }
    } catch (loadError) {
      setError((loadError as Error).message);
    } finally {
      setLoading(false);
    }
  }

  async function saveActiveProfileBanks() {
    if (!activeProfile) {
      return;
    }
    try {
      setSaving(true);
      setError(null);
      setStatusMessage(null);
      const bank_codes = dedupeSorted(editingBanks);
      const updated = await api.patch<ProfileOut>(`/profiles/${encodeURIComponent(activeProfile.key)}/banks`, {
        bank_codes,
      });
      setProfiles((prev) => prev.map((profile) => (profile.key === updated.key ? updated : profile)));
      setStatusMessage(`Saved banks for ${updated.name}`);
    } catch (saveError) {
      setError((saveError as Error).message);
    } finally {
      setSaving(false);
    }
  }

  useEffect(() => {
    loadProfiles();
  }, []);

  useEffect(() => {
    if (!activeProfile) {
      setEditingBanks([]);
      return;
    }
    setEditingBanks(activeProfile.banks);
  }, [activeProfile]);

  return (
    <section className="profile-switcher" aria-label="Profile switcher">
      <div className="profile-switcher-row">
        <strong>Profile</strong>
        <span className="muted">{loading ? 'Loading...' : null}</span>
      </div>

      <select
        value={activeProfileKey}
        onChange={(event) => {
          setStatusMessage(null);
          setActiveProfileKey(event.target.value);
        }}
      >
        {profiles.map((profile) => (
          <option key={profile.key} value={profile.key}>
            {profile.name}
          </option>
        ))}
      </select>

      <details className="profile-switcher-details">
        <summary>Edit Enabled Banks</summary>
        <div className="profile-switcher-banks">
          {allBankCodes.map((bankCode) => {
            const checked = editingBanks.includes(bankCode);
            return (
              <label key={bankCode} className="profile-switcher-bank-option">
                <input
                  type="checkbox"
                  checked={checked}
                  onChange={(event) => {
                    if (event.target.checked) {
                      setEditingBanks((prev) => dedupeSorted([...prev, bankCode]));
                      return;
                    }
                    setEditingBanks((prev) => prev.filter((item) => item !== bankCode));
                  }}
                />
                <span>{bankCode}</span>
              </label>
            );
          })}
        </div>
        <button className="primary" onClick={saveActiveProfileBanks} disabled={saving || !activeProfile}>
          {saving ? 'Saving...' : 'Save Banks'}
        </button>
      </details>

      {statusMessage ? <p className="muted">{statusMessage}</p> : null}
      {error ? <p className="error">{error}</p> : null}
    </section>
  );
}
