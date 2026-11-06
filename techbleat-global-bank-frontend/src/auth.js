import Keycloak from "keycloak-js";

const clientId = import.meta.env.VITE_KEYCLOAK_CLIENT_ID || "banking-frontend";
const keycloak = new Keycloak({
  url: import.meta.env.VITE_KEYCLOAK_URL || "https://kunleoyeleye-bank.com",   // "http://localhost:8080",
  realm: import.meta.env.VITE_KEYCLOAK_REALM || "banking",
  clientId,
});

let initialization;

export function initializeAuth() {
  if (!initialization) {
    initialization = keycloak.init({
      onLoad: "check-sso",
      pkceMethod: "S256",
      checkLoginIframe: false,
    });
  }
  return initialization;
}

export function login() {
  return keycloak.login({ redirectUri: `${window.location.origin}/` });
}

export async function getAccessToken() {
  if (!keycloak.authenticated) {
    throw new Error("Your session has expired. Please sign in again.");
  }
  await keycloak.updateToken(30);
  return keycloak.token;
}

export function getIdentity() {
  return keycloak.tokenParsed || null;
}

export function hasRole(role) {
  if (!role || !keycloak.tokenParsed) return false;
  const claims = keycloak.tokenParsed;
  const realmRoles = claims.realm_access?.roles || [];
  const clientRoles = claims.resource_access?.[clientId]?.roles || [];
  return realmRoles.includes(role) || clientRoles.includes(role);
}

export function logout() {
  return keycloak.logout({ redirectUri: window.location.origin });
}