package datamodel

import (
	"encoding/json"

	"github.com/CriticalMoments/CriticalMoments/go/cmcore"
)

type Trigger struct {
	EventName  string
	ActionName string
}

type jsonTrigger struct {
	EventName  string `json:"eventName"`
	ActionName string `json:"actionName"`
}

func (t *Trigger) UnmarshalJSON(data []byte) error {
	var jt jsonTrigger
	err := json.Unmarshal(data, &jt)
	if err != nil {
		return cmcore.NewUserPresentableErrorWSource("Unable to parse the json of a trigger. Check the format, variable names, and types (eg float vs int).", err)
	}

	t.ActionName = jt.ActionName
	t.EventName = jt.EventName

	if validationIssue := t.ValidateReturningUserReadableIssue(); validationIssue != "" {
		return cmcore.NewUserPresentableError(validationIssue)
	}

	return nil
}

// TODO pointer
func (t Trigger) Validate() bool {
	return t.ValidateReturningUserReadableIssue() == ""
}

// TODO pointer
func (t Trigger) ValidateReturningUserReadableIssue() string {
	if t.EventName == "" {
		return "All triggers require an event"
	}
	if t.ActionName == "" {
		return "All triggers require an action name"
	}
	return ""
}
