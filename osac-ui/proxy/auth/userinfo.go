package auth

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// jwtClaims decodes the payload of a JWT without signature verification.
// Safe to call on tokens we issued ourselves (from our own session cookie).
func jwtClaims(token string) (map[string]interface{}, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, fmt.Errorf("not a JWT: expected 3 parts, got %d", len(parts))
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("decode JWT payload: %w", err)
	}
	var claims map[string]interface{}
	if err := json.Unmarshal(payload, &claims); err != nil {
		return nil, fmt.Errorf("unmarshal JWT claims: %w", err)
	}
	return claims, nil
}

// UsernameFromToken extracts a human-readable username from a JWT access or ID token.
// Tries standard OIDC claims in order of preference.
func UsernameFromToken(token string) string {
	claims, err := jwtClaims(token)
	if err != nil {
		return ""
	}
	for _, key := range []string{"preferred_username", "username", "email", "sub"} {
		if v, ok := claims[key]; ok {
			if s, ok := v.(string); ok && s != "" {
				return s
			}
		}
	}
	return ""
}

// GroupsFromToken extracts group membership from a JWT token.
// Groups are read from the "groups" claim added by a Keycloak Group Membership mapper.
// Returns an empty slice when the claim is absent or the token is invalid.
func GroupsFromToken(token string) []string {
	claims, err := jwtClaims(token)
	if err != nil {
		return []string{}
	}
	rawGroups, ok := claims["groups"].([]interface{})
	if !ok {
		return []string{}
	}
	groups := make([]string, 0, len(rawGroups))
	for _, g := range rawGroups {
		if s, ok := g.(string); ok && s != "" {
			groups = append(groups, s)
		}
	}
	return groups
}

// TenantIdFromToken extracts the tenant identifier from a JWT token.
// Reads the Keycloak "organization" claim — a map keyed by organization ID.
// Returns the first organization ID found, or empty string if absent.
func TenantIdFromToken(token string) string {
	claims, err := jwtClaims(token)
	if err != nil {
		return ""
	}
	orgMap, ok := claims["organization"].(map[string]interface{})
	if !ok || len(orgMap) == 0 {
		return ""
	}
	orgIDs := make([]string, 0, len(orgMap))
	for orgID := range orgMap {
		orgIDs = append(orgIDs, orgID)
	}
	sort.Strings(orgIDs)
	return orgIDs[0]
}

// RolesFromToken extracts the raw role strings from a JWT access or ID token.
// Roles are read from the standard Keycloak claim path realm_access.roles.
// Returns an empty slice when the claim is absent or the token is invalid.
func RolesFromToken(token string) []string {
	claims, err := jwtClaims(token)
	if err != nil {
		return nil
	}
	realmAccess, ok := claims["realm_access"].(map[string]interface{})
	if !ok {
		return nil
	}
	rawRoles, ok := realmAccess["roles"].([]interface{})
	if !ok {
		return nil
	}
	roles := make([]string, 0, len(rawRoles))
	for _, r := range rawRoles {
		if s, ok := r.(string); ok && s != "" {
			roles = append(roles, s)
		}
	}
	return roles
}
