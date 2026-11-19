package mobile

import "errors"

type missingProviderResource struct{ kind, name string }

func (e *missingProviderResource) Error() string {
	return "required resource " + e.kind + "/" + e.name + " is unavailable"
}

func isMissingResource(err error) bool {
	var geo *missingGeoResource
	var provider *missingProviderResource
	return errors.As(err, &geo) || errors.As(err, &provider)
}

func (r *routingConfiguration) deferMissingResource(err error) bool {
	if !r.allowDeferredResources || !isMissingResource(err) {
		return false
	}
	r.session.resourcesPending = true
	return true
}

func (r *routingConfiguration) deferProviderResource(name string, err error) bool {
	if !r.deferMissingResource(err) {
		return false
	}
	r.deferredProviders[name] = true
	return true
}
