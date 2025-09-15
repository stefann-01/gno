test:
	$(info ************ Record Time ************)
	@echo "" | gnokey maketx call -pkgpath gno.land/r/timecheck -func RecordTime -insecure-password-stdin=true -remote http://localhost:26657 -broadcast=true -chainid dev -gas-fee 100000000ugnot -gas-wanted 1000000000 -memo "" gnoswap_admin
	@echo