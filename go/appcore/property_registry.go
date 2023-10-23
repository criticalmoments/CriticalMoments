package appcore

import (
	"errors"
	"fmt"
	"reflect"
	"strings"

	datamodel "github.com/CriticalMoments/CriticalMoments/go/cmcore/data_model"
	"github.com/antonmedv/expr"
	"golang.org/x/exp/maps"
	"golang.org/x/exp/slices"
)

const CustomPropertyPrefix = "custom_"

type propertyRegistry struct {
	providers              map[string]propertyProvider
	builtInPropertyTypes   map[string]reflect.Kind
	wellKnownPropertyTypes map[string]reflect.Kind
	dynamicFunctionNames   []string
	dynamicFunctionOps     []expr.Option
	mapFunctions           map[string]interface{}
	mapConstants           map[string]interface{}
}

func newPropertyRegistry() *propertyRegistry {
	pr := &propertyRegistry{
		providers:              make(map[string]propertyProvider),
		builtInPropertyTypes:   datamodel.BuiltInPropertyTypes(),
		wellKnownPropertyTypes: datamodel.WellKnownPropertyTypes(),
		dynamicFunctionNames:   []string{},
		dynamicFunctionOps:     []expr.Option{},
	}

	// register static/map functions
	pr.mapFunctions = datamodel.StaticConditionHelperFunctions()
	pr.mapConstants = datamodel.StaticConditionConstantProperties()

	return pr
}

func (pr *propertyRegistry) RegisterDynamicFunctions(newFuncs map[string]*datamodel.ConditionDynamicFunction) error {
	for k, v := range newFuncs {
		pr.dynamicFunctionNames = append(pr.dynamicFunctionNames, k)
		pr.dynamicFunctionOps = append(pr.dynamicFunctionOps, expr.Function(k, v.Function, v.Types...))
	}
	return nil
}

func (pr *propertyRegistry) expectedTypeForKey(key string) reflect.Kind {
	expectedType, foundType := pr.builtInPropertyTypes[key]
	if foundType {
		return expectedType
	}
	expectedType, foundType = pr.wellKnownPropertyTypes[key]
	if foundType {
		return expectedType
	}
	return reflect.Invalid
}

func (pr *propertyRegistry) addProviderForKey(key string, pp propertyProvider) error {
	if !validPropertyName(key) {
		return errors.New("invalid property name: " + key)
	}

	_, hasCurrent := pr.providers[key]
	if hasCurrent {
		fmt.Println("CriticalMoments Warning: Re-registering property provider for key: " + key)
	}

	isCustom := strings.HasPrefix(key, CustomPropertyPrefix)
	if !isCustom {
		expectedType := pr.expectedTypeForKey(key)
		if expectedType == reflect.Invalid {
			return errors.New("invalid property registered. Properties must be custom, built in or well known")
		}

		if pp.Kind() != expectedType {
			return errors.New("Property registered of wrong type (does not match expected type): " + key)
		}
	}

	validTypes := []reflect.Kind{reflect.Bool, reflect.String, reflect.Int, reflect.Float64}
	if !slices.Contains(validTypes, pp.Kind()) {
		return errors.New("Invalid property type for key: " + key)
	}

	pr.providers[key] = pp
	return nil
}

func (p *propertyRegistry) registerClientProperty(key string, value interface{}) error {
	// check not built in key
	_, isBuiltIn := p.builtInPropertyTypes[key]
	if isBuiltIn {
		return errors.New("client cannot register reserved built in property: " + key)
	}

	// Nil not supported
	if value == nil {
		return errors.New("client cannot register nil property: " + key)
	}

	// Well known types must be correct type
	wellKnownType, isWellKnown := p.wellKnownPropertyTypes[key]
	if isWellKnown {
		if reflect.TypeOf(value).Kind() != wellKnownType {
			return errors.New("property registered of wrong type (does not match expected type): " + key)
		}
	}

	// Non well known get prefixed with custom_
	updatedKey := key
	if !isWellKnown {
		updatedKey = CustomPropertyPrefix + key
	}

	return p.registerStaticProperty(updatedKey, value)
}

func (p *propertyRegistry) registerStaticProperty(key string, value interface{}) error {
	s := staticPropertyProvider{
		value: value,
	}
	return p.addProviderForKey(key, &s)
}

func (p *propertyRegistry) registerLibPropertyProvider(key string, dpp LibPropertyProvider) error {
	dw := newLibPropertyProviderWrapper(dpp)
	return p.addProviderForKey(key, &dw)
}

var errPropertyNotFound = errors.New("property not found")

func (p *propertyRegistry) propertyValue(key string) (interface{}, error) {
	v, ok := p.providers[key]
	// Allow custom properties to be accessed without the prefix
	if !ok {
		v, ok = p.providers[CustomPropertyPrefix+key]
	}
	if !ok {
		return nil, errPropertyNotFound
	}
	return v.Value(), nil
}

func (p *propertyRegistry) buildPropertyMapForCondition(fields *datamodel.ConditionFields) (map[string]interface{}, error) {
	// Extract only the used variables from the condition. Property evaluation isn't free, so
	// only evaluate those we need
	propsEnv := make(map[string]interface{})
	for _, v := range fields.Variables {
		if _, ok := propsEnv[v]; !ok {
			pv, err := p.propertyValue(v)
			if err != nil && err != errPropertyNotFound {
				return nil, err
			}
			if err == errPropertyNotFound {
				// set not-found variables to nil. Likely new var names from future SDK runing on an old SDK.
				// We want the condition string to be able to check for nil for backwards compatibility (typically "?? true" or "?? false")
				propsEnv[v] = nil
			} else {
				propsEnv[v] = pv
			}
		}
	}
	return propsEnv, nil
}

// Any unrecoginized method should return nil (not the default error)
// This is because we want to allow for backwards compatibility when newer SDKs add functions (old SDKs shouldn't fail, should return nil)
func (p *propertyRegistry) nilMethodsForUnknownFunctions(fields *datamodel.ConditionFields) ([]expr.Option, error) {
	existingFunctions := p.allFunctionNamesRegistered()
	nilFunctions := []expr.Option{}
	for _, m := range fields.Methods {
		if !slices.Contains(existingFunctions, m) {
			nfunc := expr.Function(m, func(params ...any) (interface{}, error) {
				return nil, nil
			})
			nilFunctions = append(nilFunctions, nfunc)
		}
	}

	return nilFunctions, nil
}

func (p *propertyRegistry) allFunctionNamesRegistered() []string {
	functions := []string{}
	functions = append(functions, maps.Keys(p.mapFunctions)...)
	functions = append(functions, p.dynamicFunctionNames...)

	return functions
}

func (p *propertyRegistry) evaluateCondition(condition *datamodel.Condition) (returnResult bool, returnErr error) {
	// expr can panic, so catch it and return an error instead
	defer func() {
		if r := recover(); r != nil {
			returnResult = false
			returnErr = fmt.Errorf("panic in evaluateCondition: %v", r)
		}
	}()

	// Parse the condition, extract variable and method names
	fields, err := condition.ExtractIdentifiers()
	if err != nil {
		return false, err
	}

	// Build a map of all properties(variables) used in this condition, and their values
	envMap, err := p.buildPropertyMapForCondition(fields)
	if err != nil {
		return false, err
	}

	// Add all the static constants to the environment map
	maps.Copy(envMap, p.mapConstants)

	// Add all the static functions to the environment map
	maps.Copy(envMap, p.mapFunctions)

	// Build nil function handlers for any missing functions (backwards compatibility)
	nilOps, err := p.nilMethodsForUnknownFunctions(fields)
	if err != nil {
		return false, err
	}

	mergedOptions := []expr.Option{}
	mergedOptions = append(mergedOptions, p.dynamicFunctionOps...)
	mergedOptions = append(mergedOptions, expr.Env(envMap))
	mergedOptions = append(mergedOptions, nilOps...)

	program, err := condition.CompileWithEnv(mergedOptions...)
	if err != nil {
		return false, err
	}
	result, err := expr.Run(program, envMap)
	if err != nil {
		return false, err
	}
	boolResult, ok := result.(bool)
	if !ok {
		return false, nil
	}
	return boolResult, nil
}

func (p *propertyRegistry) validateProperties() error {
	// Check built in
	for propName, expectedKind := range p.builtInPropertyTypes {
		allowMissing := datamodel.IsBuiltInPropertyOptional(propName)
		err := p.validateExpectedProvider(propName, expectedKind, allowMissing)
		if err != nil {
			return err
		}
	}

	// check well known
	for propName, expectedKind := range p.wellKnownPropertyTypes {
		err := p.validateExpectedProvider(propName, expectedKind, true)
		if err != nil {
			return err
		}
	}

	// validate any others are custom_ prefix
	for propName := range p.providers {
		_, isWellKnown := p.wellKnownPropertyTypes[propName]
		_, isBuiltIn := p.builtInPropertyTypes[propName]
		if !isWellKnown && !isBuiltIn {
			if !strings.HasPrefix(propName, CustomPropertyPrefix) {
				return fmt.Errorf("property \"%v\" is not a custom property and is not a built in or well known property", propName)
			}
		}
	}

	return nil
}

func (p *propertyRegistry) validateExpectedProvider(propName string, expectedKind reflect.Kind, allowMissing bool) error {
	provider, ok := p.providers[propName]

	if !ok && !allowMissing {
		return fmt.Errorf("missing required property: %v", propName)
	}
	if !ok && allowMissing {
		return nil
	}
	if provider.Kind() != expectedKind {
		return fmt.Errorf("property \"%v\" of wrong kind. Expected %v", propName, expectedKind.String())
	}
	return nil
}

func validPropertyName(name string) bool {
	if name == "" || name == CustomPropertyPrefix {
		return false
	}

	// if name is not alphanumeric, or an underscore, return false
	for _, c := range name {
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || (c >= 'A' && c <= 'Z')) {
			return false
		}
	}

	return true
}
