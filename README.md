<h1>Autoscale-Simplified-Template</h1>

## Using a specific version

The workshop website is built from the current `main` branch. To use an exact,
immutable version of the Terraform templates and the documentation that
accompanies them, clone a release tag instead. Replace `v2.0.0` with the release
you want to use:

```bash
git clone \
  --branch v2.0.0 \
  --single-branch \
  --depth 1 \
  https://github.com/FortinetCloudCSE/Autoscale-Simplified-Template.git \
  my-autoscale-deployment

cd my-autoscale-deployment
git switch -c my-deployment
```

Checking out a tag initially leaves Git in a detached-`HEAD` state. The final
command creates a normal branch for your environment-specific changes.

See [CHANGELOG.md](CHANGELOG.md) for the features, compatibility information,
known issues, and migration notes associated with each release.

<h3>To view the workshop, please go here: <a href="https://fortinetcloudcse.github.io/Autoscale-Simplified-Template/">Autoscale-Simplified-Template</a></h3><hr><h3>For more information on creating these workshops, please go here: <a href="https://fortinetcloudcse.github.io/UserRepo/">FortinetCloudCSE User Repo</a></h3>
