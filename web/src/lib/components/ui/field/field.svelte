<script module>
	import { cn } from "$lib/utils.js";

	const FIELD_VARIANTS = {
  "orientation": {
    "vertical": "flex-col [&>*]:w-full [&>.sr-only]:w-auto",
    "horizontal": [
      "flex-row items-center",
      "[&>[data-slot=field-label]]:flex-auto",
      "has-[>[data-slot=field-content]]:items-start has-[>[data-slot=field-content]]:[&>[role=checkbox],[role=radio]]:mt-px"
    ],
    "responsive": [
      "flex-col @md/field-group:flex-row @md/field-group:items-center [&>*]:w-full @md/field-group:[&>*]:w-auto [&>.sr-only]:w-auto",
      "@md/field-group:[&>[data-slot=field-label]]:flex-auto",
      "@md/field-group:has-[>[data-slot=field-content]]:items-start @md/field-group:has-[>[data-slot=field-content]]:[&>[role=checkbox],[role=radio]]:mt-px"
    ]
  }
};
export const fieldVariants = ({ orientation = "vertical" } = {}) =>
  cn("group/field data-[invalid=true]:text-destructive flex w-full gap-3", FIELD_VARIANTS.orientation[orientation]);
</script>

<script>

	let {
		ref = $bindable(null),
		class: className,
		orientation = "vertical",
		children,
		...restProps
	} = $props();
</script>

<div
	bind:this={ref}
	role="group"
	data-slot="field"
	data-orientation={orientation}
	class={cn(fieldVariants({ orientation }), className)}
	{...restProps}
>
	{@render children?.()}
</div>
