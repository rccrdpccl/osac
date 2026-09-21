/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package baremetalhost

import (
	metal3api "github.com/metal3-io/baremetal-operator/apis/metal3.io/v1alpha1"
	. "github.com/onsi/ginkgo/v2" //nolint:revive,staticcheck
	. "github.com/onsi/gomega"    //nolint:revive,staticcheck
)

func hdWithNICs(nics ...metal3api.NIC) *metal3api.HardwareData {
	return &metal3api.HardwareData{
		Spec: metal3api.HardwareDataSpec{
			HardwareDetails: &metal3api.HardwareDetails{NIC: nics},
		},
	}
}

func bmhWithStatusNICs(nics ...metal3api.NIC) *metal3api.BareMetalHost {
	return &metal3api.BareMetalHost{
		Status: metal3api.BareMetalHostStatus{
			HardwareDetails: &metal3api.HardwareDetails{NIC: nics},
		},
	}
}

var _ = Describe("ResolveHardwareDetails", func() {
	hdNIC := metal3api.NIC{MAC: "aa:bb:cc:dd:ee:01"}
	statusNIC := metal3api.NIC{MAC: "11:22:33:44:55:66"}

	It("returns the HardwareData details when they carry NICs", func() {
		hd := hdWithNICs(hdNIC)
		bmh := bmhWithStatusNICs(statusNIC)

		details := ResolveHardwareDetails(hd, bmh)
		Expect(details).To(Equal(hd.Spec.HardwareDetails))
		Expect(details.NIC).To(ConsistOf(hdNIC))
	})

	It("falls back to the BMH status details when HardwareData is nil", func() {
		bmh := bmhWithStatusNICs(statusNIC)

		details := ResolveHardwareDetails(nil, bmh)
		Expect(details).To(Equal(bmh.Status.HardwareDetails))
		Expect(details.NIC).To(ConsistOf(statusNIC))
	})

	It("falls back to the BMH status details when HardwareData has no NICs", func() {
		hd := hdWithNICs() // present but empty
		bmh := bmhWithStatusNICs(statusNIC)

		details := ResolveHardwareDetails(hd, bmh)
		Expect(details).To(Equal(bmh.Status.HardwareDetails))
		Expect(details.NIC).To(ConsistOf(statusNIC))
	})

	It("falls back to the BMH status when HardwareData NICs all have empty MACs", func() {
		hd := hdWithNICs(metal3api.NIC{MAC: ""}, metal3api.NIC{MAC: ""})
		bmh := bmhWithStatusNICs(statusNIC)

		details := ResolveHardwareDetails(hd, bmh)
		Expect(details).To(Equal(bmh.Status.HardwareDetails))
		Expect(details.NIC).To(ConsistOf(statusNIC))
	})

	It("prefers HardwareData when at least one NIC has a non-empty MAC", func() {
		hd := hdWithNICs(metal3api.NIC{MAC: ""}, hdNIC)
		bmh := bmhWithStatusNICs(statusNIC)

		details := ResolveHardwareDetails(hd, bmh)
		Expect(details).To(Equal(hd.Spec.HardwareDetails))
	})

	It("returns nil when HardwareData has only empty MACs and BMH has none", func() {
		hd := hdWithNICs(metal3api.NIC{MAC: ""})
		bmh := &metal3api.BareMetalHost{} // Status.HardwareDetails is nil

		Expect(ResolveHardwareDetails(hd, bmh)).To(BeNil())
	})

	It("does not let an empty HardwareData shadow a populated status", func() {
		hd := &metal3api.HardwareData{Spec: metal3api.HardwareDataSpec{}} // no HardwareDetails at all
		bmh := bmhWithStatusNICs(statusNIC)

		details := ResolveHardwareDetails(hd, bmh)
		Expect(details).To(Equal(bmh.Status.HardwareDetails))
	})

	It("returns nil when neither source has NICs", func() {
		Expect(ResolveHardwareDetails(nil, nil)).To(BeNil())
		Expect(ResolveHardwareDetails(hdWithNICs(), &metal3api.BareMetalHost{})).To(BeNil())
	})

	It("returns the nil BMH status when HardwareData is empty and BMH has none", func() {
		hd := hdWithNICs()
		bmh := &metal3api.BareMetalHost{} // Status.HardwareDetails is nil

		Expect(ResolveHardwareDetails(hd, bmh)).To(BeNil())
	})
})
